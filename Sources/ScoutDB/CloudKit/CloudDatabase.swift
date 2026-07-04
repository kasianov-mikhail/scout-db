//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// A seam shaped exactly like the CKDatabase calls the store makes — not a
/// backend abstraction. `CKDatabase` conforms by forwarding; tests inject an
/// in-memory implementation (see the `ScoutDBTesting` product) that evaluates
/// the same `CKQuery`.
///
public protocol CloudDatabase: Sendable {
    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    )
    func records(continuingMatchFrom cursor: CKQueryOperation.Cursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    )
    func save(_ record: CKRecord) async throws -> CKRecord
    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws
}

extension CloudDatabase {
    static var maxBatchSize: Int { 400 }

    func allRecords(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]? = nil) async throws -> [CKRecord] {
        var (results, cursor) = try await records(matching: query, desiredKeys: desiredKeys, resultsLimit: CKQueryOperation.maximumResults)
        while let token = cursor {
            let page = try await records(continuingMatchFrom: token, desiredKeys: desiredKeys, resultsLimit: CKQueryOperation.maximumResults)
            results += page.matchResults
            cursor = page.queryCursor
        }
        return try results.map { try $0.1.get() }
    }

    func write(record: CKRecord) async throws {
        do {
            _ = try await save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                throw error
            }
            throw RecordConflictError(serverRecord: server)
        }
    }

    func write(records: [CKRecord]) async throws {
        for chunk in records.chunked(into: Self.maxBatchSize) {
            try await modifyRecords(saving: chunk, deleting: [])
        }
    }
}

// Routes every real CloudKit call through the shared concurrency limit and a
// bounded operation configuration; the in-memory test double bypasses both
// since it never talks to the network.
//
// The conformance bodies must never spell a call that matches a CloudDatabase
// requirement's own signature: within this module such a call resolves back to
// the conformance itself, not to CloudKit, and the resulting recursion eats one
// limiter slot per level until every request deadlocks. Each body goes through
// a CloudKit API whose shape differs from the requirement it implements.
extension CKDatabase: CloudDatabase {
    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    ) {
        try await throttled { database in
            try await database.records(matching: query, inZoneWith: nil, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        }
    }

    public func records(continuingMatchFrom cursor: CKQueryOperation.Cursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    ) {
        try await throttled { database in
            try await withCheckedThrowingContinuation { continuation in
                database.fetch(withCursor: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        try await throttled { database in
            let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results.saveResults[record.recordID] else {
                throw CKError(.internalError)
            }
            return try result.get()
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await throttled { database in
            _ = try await database.modifyRecords(saving: records, deleting: recordIDs, savePolicy: .allKeys, atomically: true)
        }
    }
}

/// Thrown when a write loses a compare-and-swap race; carries the winning record.
public struct RecordConflictError: LocalizedError {
    let serverRecord: CKRecord

    public let errorDescription: String? = "The record was changed on the server"
}
