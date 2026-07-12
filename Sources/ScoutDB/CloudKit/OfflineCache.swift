//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// A `CloudDatabase` decorator that keeps working through network outages.
///
/// Reads are served from the last complete response of the same query when the
/// network fails — stale by definition, but present. Plain writes made offline
/// are queued and reported successful; `flush()` replays them once the network
/// is back, and record uuids make the replay idempotent. Queued writes are not
/// visible to reads until they flush, and conditional (CAS) saves are never
/// queued — deferring a compare-and-swap would discard its comparison.
///
public final class OfflineCache: CloudDatabase, @unchecked Sendable {
    private let backing: any CloudDatabase
    private let lock = NSLock()
    private var snapshots: [String: [CKRecord]] = [:]
    private var queuedSaves: [CKRecord] = []
    private var queuedDeletes: [CKRecord.ID] = []

    public init(backing: any CloudDatabase) {
        self.backing = backing
    }

    /// The writes waiting for `flush`, in arrival order.
    public var pendingWrites: Int {
        lock.withLock { queuedSaves.count + queuedDeletes.count }
    }

    /// Replays every queued write through the backing database.
    ///
    /// Returns how many landed; a replay that fails leaves the queue intact.
    ///
    @discardableResult public func flush() async throws -> Int {
        let (saves, deletes) = lock.withLock { (queuedSaves, queuedDeletes) }
        guard saves.count + deletes.count > 0 else { return 0 }
        try await backing.write(records: saves)
        if deletes.count > 0 {
            try await backing.modifyRecords(saving: [], deleting: deletes)
        }
        lock.withLock {
            queuedSaves.removeFirst(saves.count)
            queuedDeletes.removeFirst(deletes.count)
        }
        return saves.count + deletes.count
    }

    // A failure counts as offline when the transport, not the request, is at fault.
    static func isOffline(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(error.code)
    }

    private func cacheKey(_ query: CKQuery, _ desiredKeys: [CKRecord.FieldKey]?, _ limit: Int) -> String {
        let sorts = (query.sortDescriptors ?? []).map { "\($0.key ?? "")\($0.ascending ? "+" : "-")" }.joined(separator: ",")
        return "\(query.recordType)|\(query.predicate.predicateFormat)|\(sorts)|\(desiredKeys?.joined(separator: ",") ?? "*")|\(limit)"
    }

    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let key = cacheKey(query, desiredKeys, resultsLimit)
        do {
            let response = try await backing.records(matching: query, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
            // Only a complete response can stand in for the query later; a first
            // page served offline would silently truncate the result set.
            if response.queryCursor == nil {
                let page = response.matchResults.compactMap { try? $0.1.get() }
                lock.withLock { snapshots[key] = page }
            }
            return response
        } catch  where Self.isOffline(error) {
            guard let cached = lock.withLock({ snapshots[key] }) else { throw error }
            return (cached.map { ($0.recordID, .success($0)) }, nil)
        }
    }

    // Continuation pages are never cached — the cursor is opaque and a partial
    // snapshot would truncate offline reads.
    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        do {
            return try await backing.save(record)
        } catch  where Self.isOffline(error) {
            lock.withLock { queuedSaves.append(record) }
            return record
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        do {
            try await backing.modifyRecords(saving: records, deleting: recordIDs)
        } catch  where Self.isOffline(error) {
            lock.withLock {
                queuedSaves.append(contentsOf: records)
                queuedDeletes.append(contentsOf: recordIDs)
            }
        }
    }

    // A conditional save compares against the server; offline there is nothing to
    // compare with, so the failure propagates instead of queueing.
    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await backing.saveIfUnchanged(records)
    }

    public func save(subscription: CKSubscription) async throws {
        try await backing.save(subscription: subscription)
    }

    public func deleteSubscription(id: CKSubscription.ID) async throws {
        try await backing.deleteSubscription(id: id)
    }

    public func subscriptions() async throws -> [CKSubscription] {
        try await backing.subscriptions()
    }

    public func save(zone: CKRecordZone) async throws {
        try await backing.save(zone: zone)
    }
}
