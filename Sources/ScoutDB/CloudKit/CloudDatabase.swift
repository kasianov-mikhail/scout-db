//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// Continuation token for a paginated query.
///
/// `CKQueryOperation.Cursor` has no public initializer, so a protocol that
/// traffics in it directly forces every test double into single-page reads.
/// Real CloudKit pages carry the opaque cursor. Local scans mint
/// `materialized` — the query plus the already-matched, already-ordered ids
/// still to serve, so a continuation never re-evaluates the query.
public enum QueryCursor: @unchecked Sendable {
    case cloudKit(CKQueryOperation.Cursor)
    case materialized(query: CKQuery, remaining: [CKRecord.ID])
}

/// A seam shaped exactly like the CKDatabase calls the store makes — not a
/// backend abstraction. `CKDatabase` conforms by forwarding; tests inject an
/// in-memory implementation (see the `ScoutDBTesting` product) that evaluates
/// the same `CKQuery`.
///
public protocol CloudDatabase: Sendable {
    /// Runs a query against the database's records.
    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    )
    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    )
    func save(_ record: CKRecord) async throws -> CKRecord
    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws
    /// Saves each record only if it is unchanged on the server, non-atomically;
    /// returns the outcome of every record.
    func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)]
    func save(subscription: CKSubscription) async throws
    func deleteSubscription(id: CKSubscription.ID) async throws
    func subscriptions() async throws -> [CKSubscription]
    /// The record behind an ID, or nil when the server has none.
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord?
    /// The records behind a set of IDs, in request order; an ID the server has
    /// no record for is simply absent from the result.
    ///
    /// Records ScoutDB writes carry deterministic names, so the store reaches
    /// them by ID rather than by predicate — one request either way, but a
    /// fetch skips the query index, which lags a just-written record.
    ///
    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord]
}

/// One batch's records, carried out of the task group that fetched it.
private struct RecordBatch: @unchecked Sendable {
    let index: Int
    let records: [CKRecord]
}

extension CloudDatabase {
    static var maxBatchSize: Int { 400 }

    /// Fetches the IDs one at a time; a conformance that can fetch a batch in
    /// one request overrides this.
    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        for id in ids {
            if let record = try await fetchRecord(id: id) {
                records.append(record)
            }
        }
        return records
    }

    /// Fetches the IDs in concurrent batches of at most `batchSize`, in request
    /// order.
    ///
    /// A fetch carries a bounded number of ids, so a longer list has to be split
    /// — run as one wave rather than a batch per round trip, since the batches
    /// are independent and the request gate paces them anyway.
    ///
    func fetchRecords(ids: [CKRecord.ID], batchSize: Int) async throws -> [CKRecord] {
        guard ids.count > 0 else { return [] }
        guard ids.count > batchSize else { return try await fetchRecords(ids: ids) }
        let database = self
        return try await withThrowingTaskGroup(of: RecordBatch.self) { group in
            for (index, batch) in ids.chunked(into: batchSize).enumerated() {
                group.addTask { RecordBatch(index: index, records: try await database.fetchRecords(ids: batch)) }
            }
            var batches: [Int: [CKRecord]] = [:]
            for try await batch in group {
                batches[batch.index] = batch.records
            }
            return batches.sorted { $0.key < $1.key }.flatMap(\.value)
        }
    }

    func allRecords(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]? = nil) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        try await forEachPage(matching: query, desiredKeys: desiredKeys) { collected += $0 }
        return collected
    }

    /// Walks the query's pages, handing each one over as it lands.
    ///
    /// The shape for a pass over more records than the caller should hold at
    /// once: `allRecords` gathers every page before the first is seen, so its
    /// memory follows the whole result rather than a page of it.
    ///
    /// The cursor keeps its place in a result the body may be changing
    /// underneath it, so a record the body's own writes take out of the query
    /// can be skipped by the page that follows — a pass built on this has to be
    /// one that is safe to repeat.
    ///
    func forEachPage(
        matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]? = nil,
        _ body: ([CKRecord]) async throws -> Void
    ) async throws {
        var (results, cursor) = try await records(matching: query, desiredKeys: desiredKeys, resultsLimit: CKQueryOperation.maximumResults)
        while true {
            try await body(try results.map { try $0.1.get() })
            guard let token = cursor else { return }
            let page = try await records(continuingMatchFrom: token, desiredKeys: desiredKeys, resultsLimit: CKQueryOperation.maximumResults)
            results = page.matchResults
            cursor = page.queryCursor
        }
    }

    func write(record: CKRecord) async throws {
        do {
            _ = try await save(record)
        } catch {
            guard let conflict = RecordConflictError(error) else { throw error }
            throw conflict
        }
    }

    func write(records: [CKRecord]) async throws {
        for chunk in records.chunked(into: Self.maxBatchSize) {
            do {
                try await modifyRecords(saving: chunk, deleting: [])
            } catch let error as CKError {
                throw PartialWriteError(error) ?? error
            }
        }
    }

    func delete(records ids: [CKRecord.ID]) async throws {
        for chunk in ids.chunked(into: Self.maxBatchSize) {
            try await modifyRecords(saving: [], deleting: chunk)
        }
    }

    func writeIfUnchanged(records: [CKRecord]) async throws -> [CKRecord] {
        var conflicts: [CKRecord] = []
        for chunk in records.chunked(into: Self.maxBatchSize) {
            for (_, result) in try await saveIfUnchanged(chunk) {
                guard case .failure(let error) = result else { continue }
                guard let conflict = RecordConflictError(error) else { throw error }
                conflicts.append(conflict.serverRecord)
            }
        }
        return conflicts
    }
}

extension CKDatabase: CloudDatabase {
    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        do {
            return try await throttled { database in
                let (results, cursor) = try await database.records(matching: query, inZoneWith: nil, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
                return (results, cursor.map(QueryCursor.cloudKit))
            }
        } catch let error as CKError where error.code == .unknownItem {
            return ([], nil)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        guard case .cloudKit(let cursor) = cursor else { throw CKError(.invalidArguments) }
        return try await throttled { database in
            let (results, next): (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?) =
                try await withCheckedThrowingContinuation { continuation in
                    database.fetch(withCursor: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit) { result in
                        continuation.resume(with: result)
                    }
                }
            return (results, next.map(QueryCursor.cloudKit))
        }
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        try await throttled { database in
            do {
                let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let result = results.saveResults[record.recordID] else {
                    throw CKError(.internalError)
                }
                return try result.get()
            } catch let error as CKError where error.code == .partialFailure {
                guard let perItem = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error],
                    let cause = perItem[record.recordID]
                else {
                    throw error
                }
                throw cause
            }
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await throttled { database in
            _ = try await database.modifyRecords(saving: records, deleting: recordIDs, savePolicy: .allKeys, atomically: true)
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await throttled { database in
            let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            return records.map { record in
                guard let result = results.saveResults[record.recordID] else {
                    return (record.recordID, .failure(CKError(.internalError)))
                }
                guard case .failure(let error) = result, let conflict = RecordConflictError(error) else {
                    return (record.recordID, result)
                }
                return (record.recordID, .failure(conflict))
            }
        }
    }

    public func save(subscription: CKSubscription) async throws {
        try await throttled { database in
            let results = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            _ = try results.saveResults[subscription.subscriptionID]?.get()
        }
    }

    public func deleteSubscription(id: CKSubscription.ID) async throws {
        try await throttled { database in
            let results = try await database.modifySubscriptions(saving: [], deleting: [id])
            _ = try results.deleteResults[id]?.get()
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await throttled { database in
            do {
                return try await database.records(for: [id])[id]?.get()
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        guard ids.count > 0 else { return [] }
        return try await throttled { database in
            let results = try await database.records(for: ids)
            return try ids.compactMap { id in
                guard let result = results[id] else { return nil }
                do {
                    return try result.get()
                } catch let error as CKError where error.code == .unknownItem {
                    return nil
                }
            }
        }
    }

    public func subscriptions() async throws -> [CKSubscription] {
        try await throttled { database in
            try await withCheckedThrowingContinuation { continuation in
                database.fetchAllSubscriptions { subscriptions, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: subscriptions ?? [])
                    }
                }
            }
        }
    }
}

/// A batch write that failed for some of its records, unwrapped per record.
///
/// CloudKit rolls back an atomic batch when any record fails and marks the
/// innocent rest with `batchRequestFailed` — the raw `partialFailure` buries
/// the actual cause in `userInfo`. This error keeps only the failures that
/// caused the rollback, keyed by record.
///
public struct PartialWriteError: LocalizedError {
    public let reasons: [CKRecord.ID: any Error]

    init?(_ error: CKError) {
        guard error.code == .partialFailure, let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error] else { return nil }
        let causes = partial.filter { ($0.value as? CKError)?.code != .batchRequestFailed }
        guard causes.count > 0 else { return nil }
        reasons = causes
    }

    public var errorDescription: String? {
        "\(reasons.count) record(s) failed the batch write"
    }
}

/// Thrown when a write loses a compare-and-swap race; carries the winning record.
public struct RecordConflictError: LocalizedError {
    public let serverRecord: CKRecord

    public init(serverRecord: CKRecord) {
        self.serverRecord = serverRecord
    }

    /// The conflict behind a failed conditional save, whether the database
    /// reported it as this error or as CloudKit's own `serverRecordChanged`.
    ///
    /// Nil for anything else — a permission, quota or validation failure is
    /// not a lost race and must not be retried as one.
    ///
    public init?(_ error: any Error) {
        if let conflict = error as? RecordConflictError {
            self = conflict
        } else if let error = error as? CKError, error.code == .serverRecordChanged,
            let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        {
            self.init(serverRecord: server)
        } else {
            return nil
        }
    }

    public let errorDescription: String? = "The record was changed on the server"
}
