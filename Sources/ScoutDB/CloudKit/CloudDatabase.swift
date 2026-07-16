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
/// Real CloudKit pages carry the opaque cursor; in-memory implementations
/// carry the query plus how many matches the previous pages already delivered.
public enum QueryCursor: @unchecked Sendable {
    case cloudKit(CKQueryOperation.Cursor)
    case offset(query: CKQuery, zoneID: CKRecordZone.ID?, offset: Int)
}

/// A seam shaped exactly like the CKDatabase calls the store makes — not a
/// backend abstraction. `CKDatabase` conforms by forwarding; tests inject an
/// in-memory implementation (see the `ScoutDBTesting` product) that evaluates
/// the same `CKQuery`.
///
public protocol CloudDatabase: Sendable {
    /// Runs a query, in one zone when `zoneID` is given, across all zones otherwise.
    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
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
    func save(zone: CKRecordZone) async throws
    /// The record behind an ID, or nil when the server has none.
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord?
    /// One pass of a zone's change feed from an opaque continuation token;
    /// `desiredKeys` trims every changed record to those fields (nil fetches
    /// whole records). A `resultsLimit` stops the pass after roughly that many
    /// changes with an intermediate token — the batched walk behind sync
    /// progress; nil drains the feed in one pass. A drained feed answers a
    /// limited pass with an empty batch.
    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    )
    /// One pass of the database's zone-level change feed: which zones gained
    /// changes, which disappeared. The discovery step for accepted shares —
    /// run it on the shared database, then build a zone-scoped store per zone
    /// (seed its registry with `register(_:)`, schemas live in the owner's
    /// default zone).
    func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?)
}

extension CloudDatabase {
    static var maxBatchSize: Int { 400 }

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?) async throws -> (changed: [CKRecord], deleted: [CKRecord.ID], token: Data?) {
        try await zoneChanges(zoneID: zoneID, since: token, desiredKeys: nil, resultsLimit: nil)
    }

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: nil)
    }

    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await records(matching: query, inZone: nil, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func allRecords(matching query: CKQuery, inZone zoneID: CKRecordZone.ID? = nil, desiredKeys: [CKRecord.FieldKey]? = nil) async throws -> [CKRecord] {
        var (results, cursor) = try await records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: CKQueryOperation.maximumResults)
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
            do {
                try await modifyRecords(saving: chunk, deleting: [])
            } catch let error as CKError {
                throw PartialWriteError(error) ?? error
            }
        }
    }

    // The CAS counterpart of `write(records:)`: attempts every record under the
    // if-unchanged policy and returns the winning server records of the saves that
    // lost their race; any failure that is not a lost race throws.
    func writeIfUnchanged(records: [CKRecord]) async throws -> [CKRecord] {
        var conflicts: [CKRecord] = []
        for chunk in records.chunked(into: Self.maxBatchSize) {
            for (_, result) in try await saveIfUnchanged(chunk) {
                guard case .failure(let error) = result else { continue }
                if let conflict = error as? RecordConflictError {
                    conflicts.append(conflict.serverRecord)
                } else if let error = error as? CKError, error.code == .serverRecordChanged,
                    let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
                {
                    conflicts.append(server)
                } else {
                    throw error
                }
            }
        }
        return conflicts
    }
}

// Routes every real CloudKit call through a bounded operation configuration,
// a backstop timeout, and rate-limit retries; the in-memory test double
// bypasses all of that since it never talks to the network.
//
// The conformance bodies must never spell a call that matches a CloudDatabase
// requirement's own signature: within this module such a call resolves back to
// the conformance itself, not to CloudKit, and the resulting recursion never
// reaches the server. Each body goes through a CloudKit API whose shape
// differs from the requirement it implements.
extension CKDatabase: CloudDatabase {
    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        do {
            return try await throttled { database in
                let (results, cursor) = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
                return (results, cursor.map(QueryCursor.cloudKit))
            }
        } catch let error as CKError where error.code == .unknownItem {
            // A record type nobody has written yet does not exist server-side and
            // its query throws, unlike a written-then-emptied one. ScoutDB's
            // record types are fixed internal names, so the miss can only mean
            // "no rows yet" — the answer an empty type would give.
            return ([], nil)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        // An offset cursor can only come from a test double; feeding it back into
        // real CloudKit is a caller bug.
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

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await throttled { database in
            let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            return records.map { record in
                (record.recordID, results.saveResults[record.recordID] ?? .failure(CKError(.internalError)))
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

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        let previous = try token.map { data in
            guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
                throw CKError(.invalidArguments)
            }
            return unarchived
        }
        return try await throttled { database in
            // The operation reports through callbacks on its own queue, one at a
            // time; the box only bridges that serial stream into the continuation.
            final class Collector: @unchecked Sendable {
                var changed: [CKRecordZone.ID] = []
                var deleted: [CKRecordZone.ID] = []
                var latest: CKServerChangeToken?
            }
            let collector = Collector()

            return try await withCheckedThrowingContinuation { continuation in
                let operation = CKFetchDatabaseChangesOperation(previousServerChangeToken: previous)
                operation.recordZoneWithIDChangedBlock = { zoneID in
                    collector.changed.append(zoneID)
                }
                operation.recordZoneWithIDWasDeletedBlock = { zoneID in
                    collector.deleted.append(zoneID)
                }
                operation.recordZoneWithIDWasPurgedBlock = { zoneID in
                    collector.deleted.append(zoneID)
                }
                operation.changeTokenUpdatedBlock = { token in
                    collector.latest = token
                }
                operation.fetchDatabaseChangesResultBlock = { result in
                    switch result {
                    case .success((let token, _)):
                        let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                        continuation.resume(returning: (collector.changed, collector.deleted, archived))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        }
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        let previous = try token.map { data in
            guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
                throw CKError(.invalidArguments)
            }
            return unarchived
        }
        return try await throttled { database in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = previous
            configuration.desiredKeys = desiredKeys
            if let resultsLimit {
                configuration.resultsLimit = resultsLimit
            }

            // The operation reports through callbacks on its own queue, one at a
            // time; the box only bridges that serial stream into the continuation.
            final class Collector: @unchecked Sendable {
                var changed: [CKRecord] = []
                var deleted: [CKRecord.ID] = []
                var latest: CKServerChangeToken?
            }
            let collector = Collector()

            return try await withCheckedThrowingContinuation { continuation in
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
                // A limited pass returns one batch with its intermediate token
                // instead of chasing moreComing to the end of the feed.
                operation.fetchAllChanges = resultsLimit == nil
                operation.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result {
                        collector.changed.append(record)
                    }
                }
                operation.recordWithIDWasDeletedBlock = { id, _ in
                    collector.deleted.append(id)
                }
                operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                    collector.latest = token
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    if case .success((let token, _, _)) = result {
                        collector.latest = token
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        let data = collector.latest.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                        continuation.resume(returning: (collector.changed, collector.deleted, data))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        }
    }

    public func save(zone: CKRecordZone) async throws {
        try await throttled { database in
            let results = try await database.modifyRecordZones(saving: [zone], deleting: [])
            _ = try results.saveResults[zone.zoneID]?.get()
        }
    }

    public func subscriptions() async throws -> [CKSubscription] {
        try await throttled { database in
            // Fetching by an empty ID list returns nothing, so the conformance goes
            // through the all-subscriptions operation; its shape differs from the
            // requirement, keeping the call out of the conformance itself.
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

    public let errorDescription: String? = "The record was changed on the server"
}
