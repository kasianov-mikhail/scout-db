//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// A `CloudDatabase` decorator that keeps a local replica of one zone and
/// answers any query from it when the network fails.
///
/// Where `OfflineCache` replays snapshots of queries it has already seen, the
/// replica mirrors the zone's records themselves and runs the query locally —
/// filters, sorts, pagination, and projections included, through the same
/// evaluation the in-memory test double uses. The mirror feeds three ways:
/// every successful write through this database lands in it, every
/// full-fidelity `zoneChanges` pass flowing through applies its delta (a
/// `SyncCoordinator` keeps it fresh for free), and `refresh()` walks the feed
/// from the replica's own token for a complete mirror. With a `storeURL` the
/// mirror persists across launches.
///
/// Compose it outside an `OfflineCache` —
/// `ReplicaCache(backing: OfflineCache(backing: db), zoneID: zone)` — and a
/// write queued offline still reaches the mirror, so novel offline queries
/// read your writes; a flush that later merges or conflicts is corrected by
/// the next feed pass. Queries outside the replica's zone pass through
/// untouched. The mirror holds the whole zone by design; it is a replica,
/// not a bounded cache.
///
/// With `readPolicy: .localFirst` the mirror becomes the primary read path:
/// once a refresh has drained the feed, reads of the zone never touch the
/// network — no round trip online, no timeout to wait out offline — and
/// freshness comes from the coordinator passes and refreshes that feed the
/// mirror. A stale local copy caught in a conditional save conflicts and
/// retries against the winner, exactly like a stale server page would.
///
public final class ReplicaCache: CloudDatabase, @unchecked Sendable {
    /// When the mirror answers reads of the replica's zone.
    public enum ReadPolicy: Sendable {
        /// Reads go to the server; the mirror answers when the network fails.
        case networkFirst
        /// Reads of the zone are answered from the mirror immediately — no
        /// network round trip, no offline timeout to wait out. Freshness comes
        /// from the passes that feed the mirror: a `SyncCoordinator`, or
        /// `refresh()`. Until the first refresh completes the policy behaves
        /// like `networkFirst` — a half-built mirror must not silently answer
        /// with partial results.
        case localFirst
    }

    private let backing: any CloudDatabase
    private let zoneID: CKRecordZone.ID
    private let storeURL: URL?
    private let readPolicy: ReadPolicy
    private let lock = NSLock()
    private var mirror: [CKRecord.ID: CKRecord] = [:]
    // The replica's own feed position — advanced only by refresh(), which is
    // the one path that guarantees the mirror saw everything before it.
    private var token: Data?
    // Whether a refresh() ever drained the feed; the gate for localFirst.
    private var complete = false

    public init(backing: any CloudDatabase, zoneID: CKRecordZone.ID, storeURL: URL? = nil, readPolicy: ReadPolicy = .networkFirst) {
        self.backing = backing
        self.zoneID = zoneID
        self.storeURL = storeURL
        self.readPolicy = readPolicy
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            restore(from: data)
        }
    }

    /// How many records the mirror currently holds.
    public var recordCount: Int {
        lock.withLock { mirror.count }
    }

    /// Whether a `refresh()` has ever drained the feed — the point from which
    /// the mirror holds the whole zone and `localFirst` starts serving.
    public var hasCompleteMirror: Bool {
        lock.withLock { complete }
    }

    // Whether this read of the zone should skip the network entirely.
    private func servesLocally(_ zoneID: CKRecordZone.ID?) -> Bool {
        guard case .localFirst = readPolicy, zoneID == self.zoneID else { return false }
        return lock.withLock { complete }
    }

    /// Walks the zone's change feed from the replica's own position until it
    /// drains, applying every batch to the mirror.
    ///
    /// The one call that guarantees a complete mirror — the passive feeding
    /// only sees what happens to flow through. Batches keep memory flat and
    /// the position advances per batch, so an interrupted refresh resumes
    /// where it stopped. Returns how many changes were applied.
    ///
    @discardableResult public func refresh(batchSize: Int = 200) async throws -> Int {
        var applied = 0
        while true {
            let since = lock.withLock { token }
            let (changed, deleted, next) = try await backing.zoneChanges(zoneID: zoneID, since: since, desiredKeys: nil, resultsLimit: batchSize)
            guard changed.count + deleted.count > 0 else {
                lock.withLock {
                    complete = true
                    persistLocked()
                }
                return applied
            }
            applied += changed.count + deleted.count
            lock.withLock {
                applyLocked(changed: changed, deleted: deleted)
                token = next ?? token
                persistLocked()
            }
        }
    }

    // MARK: - Mirror maintenance

    private func applyLocked(changed: [CKRecord], deleted: [CKRecord.ID]) {
        for record in changed {
            mirror[record.recordID] = LocalQuery.project(record, keys: nil)
        }
        for id in deleted {
            mirror[id] = nil
        }
    }

    private func upsert(_ records: [CKRecord], deleting deleted: [CKRecord.ID] = []) {
        let mine = records.filter { $0.recordID.zoneID == zoneID }
        let gone = deleted.filter { $0.zoneID == zoneID }
        guard mine.count + gone.count > 0 else { return }
        lock.withLock {
            applyLocked(changed: mine, deleted: gone)
            persistLocked()
        }
    }

    private func restore(from data: Data) {
        let classes = [NSDictionary.self, NSArray.self, NSString.self, NSData.self, CKRecord.self]
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any] else { return }
        mirror = (root["records"] as? [CKRecord] ?? []).reduce(into: [:]) { $0[$1.recordID] = $1 }
        token = root["token"] as? Data
        complete = (root["complete"] as? NSNumber)?.boolValue ?? false
    }

    private func persistLocked() {
        guard let storeURL else { return }
        var root: [String: Any] = ["records": Array(mirror.values), "complete": NSNumber(value: complete)]
        root["token"] = token
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Reads

    // The mirror in a stable scan order: offset cursors page a dictionary, so
    // consecutive pages must walk the same sequence.
    private var scanOrderLocked: [CKRecord] {
        mirror.values.sorted { $0.recordID.recordName < $1.recordID.recordName }
    }

    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws
        -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?)
    {
        if servesLocally(zoneID) {
            return lock.withLock {
                LocalQuery.page(scanOrderLocked, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
            }
        }
        do {
            let response = try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
            // A full-fidelity page is fresh server truth — fold it into the
            // mirror; a projected one misses fields and cannot.
            if zoneID == self.zoneID, desiredKeys == nil {
                upsert(response.matchResults.compactMap { try? $0.1.get() })
            }
            return response
        } catch  where OfflineCache.isOffline(error) && zoneID == self.zoneID {
            return lock.withLock {
                LocalQuery.page(scanOrderLocked, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
            }
        }
    }

    // A continuation the replica minted offline carries an offset cursor. The
    // backing rejects it as invalid when the network is back mid-scan — the
    // mirror keeps serving that scan to its end either way.
    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        // A localFirst scan of the zone stays on the mirror to its end — its
        // offset cursors are the mirror's own.
        if case .offset(let query, let zoneID, let offset) = cursor, servesLocally(zoneID) {
            return lock.withLock {
                LocalQuery.page(scanOrderLocked, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit)
            }
        }
        do {
            return try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        } catch {
            guard case .offset(let query, let zoneID, let offset) = cursor, zoneID == self.zoneID,
                OfflineCache.isOffline(error) || (error as? CKError)?.code == .invalidArguments
            else { throw error }
            return lock.withLock {
                LocalQuery.page(scanOrderLocked, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit)
            }
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        if servesLocally(id.zoneID) {
            return lock.withLock { mirror[id].map { LocalQuery.project($0, keys: nil) } }
        }
        do {
            let record = try await backing.fetchRecord(id: id)
            if let record {
                upsert([record])
            }
            return record
        } catch  where OfflineCache.isOffline(error) && id.zoneID == zoneID {
            return lock.withLock { mirror[id].map { LocalQuery.project($0, keys: nil) } }
        }
    }

    // MARK: - Writes feed the mirror

    public func save(_ record: CKRecord) async throws -> CKRecord {
        let saved = try await backing.save(record)
        upsert([saved])
        return saved
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await backing.modifyRecords(saving: records, deleting: recordIDs)
        upsert(records, deleting: recordIDs)
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        let results = try await backing.saveIfUnchanged(records)
        upsert(results.compactMap { try? $0.1.get() })
        return results
    }

    // MARK: - Feed passes flowing through

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        let response = try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        // A projected pass cannot feed the mirror: its records miss fields,
        // and overwriting a full record with a trimmed one would lose them.
        if zoneID == self.zoneID, desiredKeys == nil {
            upsert(response.changed, deleting: response.deleted)
        }
        return response
    }

    // MARK: - Pass-throughs

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

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}
