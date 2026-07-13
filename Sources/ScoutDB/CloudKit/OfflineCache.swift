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
/// is back, and record uuids make the replay idempotent. The replay is
/// conflict-aware: every save runs under the if-unchanged policy, offline edits
/// are grafted onto a server record that moved when the two sides touched
/// disjoint fields, and overlapping edits surface as `OfflineFlushError`
/// instead of overwriting the server. Queued writes are not visible to reads
/// until they flush, and conditional (CAS) saves are never queued — deferring
/// a compare-and-swap would discard its comparison.
///
public final class OfflineCache: CloudDatabase, @unchecked Sendable {
    private let backing: any CloudDatabase
    private let storeURL: URL?
    private let lock = NSLock()
    private var snapshots: [String: [CKRecord]] = [:]
    private var queuedSaves: [CKRecord] = []
    private var queuedDeletes: [CKRecord.ID] = []
    // The last full server copy seen per record — the merge base a conflicted
    // flush diffs both sides against.
    private var baselines: [CKRecord.ID: CKRecord] = [:]
    private let snapshotLimit: Int
    private let baselineLimit: Int
    private var conflictResolver: (any ConflictResolver)?
    // Recency bookkeeping for the LRU quotas; not persisted, so restored
    // entries count as oldest until traffic touches them again.
    private var snapshotUsage: [String: Int64] = [:]
    private var baselineUsage: [CKRecord.ID: Int64] = [:]
    private var clock: Int64 = 0

    /// With a `storeURL`, snapshots and the write queue persist across launches:
    /// every mutation archives the state to the file (best-effort — a failed
    /// write costs freshness, not correctness), and init restores it.
    ///
    /// The quotas keep the cache bounded: at most `snapshotLimit` query
    /// snapshots and `baselineLimit` merge baselines, evicted least-recently
    /// used. An evicted snapshot costs offline coverage of that query; an
    /// evicted baseline degrades a conflicting flush from a merge to a
    /// surfaced conflict — never correctness.
    ///
    /// A `conflictResolver` decides the conflicts the graft cannot merge —
    /// without one they surface as `OfflineFlushError`.
    ///
    public init(
        backing: any CloudDatabase, storeURL: URL? = nil, snapshotLimit: Int = 50, baselineLimit: Int = 500,
        conflictResolver: (any ConflictResolver)? = nil
    ) {
        self.backing = backing
        self.storeURL = storeURL
        self.snapshotLimit = snapshotLimit
        self.baselineLimit = baselineLimit
        self.conflictResolver = conflictResolver
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            restore(from: data)
            lock.withLock { enforceQuotasLocked() }
        }
    }

    private func enforceQuotasLocked() {
        while snapshots.count > snapshotLimit, let victim = snapshots.keys.min(by: { snapshotUsage[$0] ?? 0 < snapshotUsage[$1] ?? 0 }) {
            snapshots[victim] = nil
            snapshotUsage[victim] = nil
        }
        while baselines.count > baselineLimit, let victim = baselines.keys.min(by: { baselineUsage[$0] ?? 0 < baselineUsage[$1] ?? 0 }) {
            baselines[victim] = nil
            baselineUsage[victim] = nil
        }
    }

    private func touchSnapshotLocked(_ key: String) {
        clock += 1
        snapshotUsage[key] = clock
    }

    private func touchBaselineLocked(_ id: CKRecord.ID) {
        clock += 1
        baselineUsage[id] = clock
    }

    private func restore(from data: Data) {
        let classes = [NSDictionary.self, NSArray.self, NSString.self, CKRecord.self, CKRecord.ID.self]
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any] else { return }
        snapshots = root["snapshots"] as? [String: [CKRecord]] ?? [:]
        queuedSaves = root["saves"] as? [CKRecord] ?? []
        queuedDeletes = root["deletes"] as? [CKRecord.ID] ?? []
        baselines = (root["baselines"] as? [CKRecord] ?? []).reduce(into: [:]) { $0[$1.recordID] = $1 }
    }

    // Callers hold the lock; the archive is a full rewrite, small by design
    // (complete query snapshots plus the pending queue).
    private func persistLocked() {
        guard let storeURL else { return }
        let root: [String: Any] = [
            "snapshots": snapshots, "saves": queuedSaves, "deletes": queuedDeletes, "baselines": Array(baselines.values),
        ]
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Installs or replaces the flush conflict policy.
    ///
    /// The one hook that must outlive init: a decoded resolver is built from
    /// an `EntityStore`, and the store wraps this cache — construct the cache,
    /// the store, then install `store.conflictResolver { ... }` here.
    ///
    public func setConflictResolver(_ resolver: (any ConflictResolver)?) {
        lock.withLock { conflictResolver = resolver }
    }

    /// The writes waiting for `flush`, in arrival order.
    public var pendingWrites: Int {
        lock.withLock { queuedSaves.count + queuedDeletes.count }
    }

    /// One write sitting in the offline queue.
    public enum QueuedWrite: @unchecked Sendable {
        /// A record save awaiting replay; the record is a defensive copy.
        case save(CKRecord)
        /// A deletion awaiting replay.
        case delete(CKRecord.ID)
    }

    /// The queued writes awaiting `flush`: saves in replay order, then deletes.
    ///
    /// The records are defensive copies — mutating one does not edit the queue.
    /// Use `discardQueuedWrites(for:)` to drop an entry that should not replay.
    ///
    public var queuedWrites: [QueuedWrite] {
        lock.withLock {
            queuedSaves.map { .save($0.copy() as! CKRecord) } + queuedDeletes.map(QueuedWrite.delete)
        }
    }

    /// Drops every queued write that targets the given record, without replaying it.
    ///
    /// Asset copies retained for the dropped saves are discarded with them.
    /// Returns how many queue entries were removed. Offline reads stop seeing
    /// the discarded edit and serve the snapshotted server copy again.
    ///
    @discardableResult public func discardQueuedWrites(for id: CKRecord.ID) -> Int {
        lock.withLock {
            let dropped = queuedSaves.filter { $0.recordID == id }
            let deletes = queuedDeletes.count
            queuedSaves.removeAll { $0.recordID == id }
            queuedDeletes.removeAll { $0 == id }
            let removed = dropped.count + deletes - queuedDeletes.count
            guard removed > 0 else { return 0 }
            EntityCoder.discardStagedAssets(in: dropped)
            persistLocked()
            return removed
        }
    }

    /// Replays every queued write through the backing database.
    ///
    /// Every save replays under the if-unchanged policy. A record whose server
    /// copy moved while the write sat in the queue is merged when the two edits
    /// touched disjoint fields; overlapping edits surface in an
    /// `OfflineFlushError` — never a blind overwrite. Returns how many writes
    /// landed; a transport failure leaves the unreplayed writes queued for the
    /// next attempt.
    ///
    @discardableResult public func flush() async throws -> Int {
        let (saves, deletes) = lock.withLock { (queuedSaves, queuedDeletes) }
        guard saves.count + deletes.count > 0 else { return 0 }
        var conflicts: [OfflineFlushError.Conflict] = []
        var landed: [CKRecord] = []
        do {
            for record in saves {
                if let conflict = try await push(record) {
                    conflicts.append(conflict)
                } else {
                    landed.append(record)
                    // The asset copies retained at queueing time were only
                    // needed for this upload.
                    EntityCoder.discardStagedAssets(in: [record])
                }
            }
            if deletes.count > 0 {
                try await backing.modifyRecords(saving: [], deleting: deletes)
            }
        } catch {
            // A transport failure keeps everything unreplayed — including the
            // conflicts found so far, so the next flush reports them again.
            dequeue(saves: landed, deletes: [])
            throw error
        }
        // Conflicted saves leave the queue too: they are handed to the caller,
        // and replaying them verbatim could never succeed.
        dequeue(saves: saves, deletes: deletes)
        guard conflicts.isEmpty else { throw OfflineFlushError(conflicts: conflicts) }
        return saves.count + deletes.count
    }

    // Removes the replayed writes from the queue — by identity for saves and
    // one occurrence per ID for deletes, so a concurrent `discardQueuedWrites`
    // never shifts what gets dequeued.
    private func dequeue(saves: [CKRecord], deletes: [CKRecord.ID]) {
        lock.withLock {
            let replayed = Set(saves.map(ObjectIdentifier.init))
            queuedSaves.removeAll { replayed.contains(ObjectIdentifier($0)) }
            var remaining = deletes
            queuedDeletes.removeAll { id in
                guard let index = remaining.firstIndex(of: id) else { return false }
                remaining.remove(at: index)
                return true
            }
            persistLocked()
        }
    }

    // Replays one queued save under the if-unchanged policy, re-merging against
    // the moving server record a bounded number of times. Returns the conflict
    // when the edits overlap; transport and other non-conflict errors throw.
    private func push(_ record: CKRecord) async throws -> OfflineFlushError.Conflict? {
        var attempt = record
        var retries = 3
        while true {
            do {
                for (_, result) in try await backing.saveIfUnchanged([attempt]) {
                    _ = try result.get()
                }
                return nil
            } catch {
                guard let server = Self.conflictingServerRecord(in: error) else { throw error }
                retries -= 1
                guard retries > 0 else { return OfflineFlushError.Conflict(queued: record, server: server) }
                if let merged = graft(record, onto: server) {
                    attempt = merged
                    continue
                }
                switch await resolve(record, against: server) {
                case .save(let resolved): attempt = resolved
                case .keepServer: return nil
                case .surface: return OfflineFlushError.Conflict(queued: record, server: server)
                }
            }
        }
    }

    // Hands a graft-proof conflict to the app's resolver. A record it returns
    // must compare as the server copy it saw, so the server's version tag is
    // carried onto it before the retry.
    private func resolve(_ queued: CKRecord, against server: CKRecord) async -> ConflictResolution {
        guard let conflictResolver = lock.withLock({ conflictResolver }) else { return .surface }
        let ancestor = lock.withLock { baselines[queued.recordID] }
        let resolution = await conflictResolver.resolve(queued: queued, server: server, ancestor: ancestor)
        if case .save(let resolved) = resolution, let tag = server.recordVersionTag {
            resolved.overrideChangeTag(tag)
        }
        return resolution
    }

    private static func conflictingServerRecord(in error: any Error) -> CKRecord? {
        if let conflict = error as? RecordConflictError { return conflict.serverRecord }
        if let error = error as? CKError, error.code == .serverRecordChanged {
            return error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }
        return nil
    }

    // The queued record's edits applied on top of the winning server record —
    // but only when the two sides changed disjoint fields relative to the last
    // server copy this cache saw. Without that baseline, or with both sides
    // moving one field to different values, there is nothing safe to merge.
    private func graft(_ queued: CKRecord, onto server: CKRecord) -> CKRecord? {
        let ancestor = lock.withLock { () -> CKRecord? in
            guard let ancestor = baselines[queued.recordID] else { return nil }
            touchBaselineLocked(queued.recordID)
            return ancestor
        }
        guard let ancestor else { return nil }
        let mine = Self.changedValues(from: ancestor, to: queued)
        let theirs = Self.changedValues(from: ancestor, to: server)
        for (key, value) in mine {
            guard let their = theirs[key], !Self.equalValues(value, their) else { continue }
            return nil
        }
        let merged = server.copy() as! CKRecord
        // A real record's change tag survives the copy; a testing override does
        // not, so carry it over — the retried save must compare as the server
        // copy it was built from.
        if let tag = server.recordVersionTag {
            merged.overrideChangeTag(tag)
        }
        for (key, value) in mine {
            merged[key] = value
        }
        return merged
    }

    // The fields whose values differ between two states of one record; a field
    // the later state removed carries nil.
    private static func changedValues(from ancestor: CKRecord, to record: CKRecord) -> [String: CKRecordValue?] {
        var changes: [String: CKRecordValue?] = [:]
        for key in Set(ancestor.allKeys()).union(record.allKeys()) where !equalValues(ancestor[key], record[key]) {
            changes.updateValue(record[key], forKey: key)
        }
        return changes
    }

    private static func equalValues(_ lhs: CKRecordValue?, _ rhs: CKRecordValue?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return (lhs as? NSObject)?.isEqual(rhs) == true
        default: return false
        }
    }

    // A failure counts as offline when the transport, not the request, is at fault.
    static func isOffline(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(error.code)
    }

    private func cacheKey(_ query: CKQuery, _ zoneID: CKRecordZone.ID?, _ desiredKeys: [CKRecord.FieldKey]?, _ limit: Int) -> String {
        let sorts = (query.sortDescriptors ?? []).map { "\($0.key ?? "")\($0.ascending ? "+" : "-")" }.joined(separator: ",")
        let zone = zoneID.map { "\($0.zoneName)@\($0.ownerName)" } ?? "*"
        return "\(query.recordType)|\(zone)|\(query.predicate.predicateFormat)|\(sorts)|\(desiredKeys?.joined(separator: ",") ?? "*")|\(limit)"
    }

    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let key = cacheKey(query, zoneID, desiredKeys, resultsLimit)
        do {
            let response = try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
            let page = response.matchResults.compactMap { try? $0.1.get() }
            lock.withLock {
                // A full-fidelity response refreshes the merge baselines; a
                // projected one cannot — its missing keys would later read as
                // fields the offline edit removed.
                if desiredKeys == nil {
                    for record in page {
                        baselines[record.recordID] = record
                        touchBaselineLocked(record.recordID)
                    }
                }
                // Only a complete response can stand in for the query later; a first
                // page served offline would silently truncate the result set.
                if response.queryCursor == nil {
                    snapshots[key] = page
                    touchSnapshotLocked(key)
                }
                if desiredKeys == nil || response.queryCursor == nil {
                    enforceQuotasLocked()
                    persistLocked()
                }
            }
            return response
        } catch  where Self.isOffline(error) {
            let cached = lock.withLock { () -> [CKRecord]? in
                guard let overlaid = overlaidLocked(snapshots[key]) else { return nil }
                touchSnapshotLocked(key)
                return overlaid
            }
            guard let cached else { throw error }
            return (cached.map { ($0.recordID, .success($0)) }, nil)
        }
    }

    // The queued writes overlaid onto a snapshot: a queued rewrite of a record
    // the snapshot already holds replaces it (read-your-updates, tombstones
    // included), a queued delete drops it. A queued *new* record cannot join —
    // the query's predicate cannot run offline.
    private func overlaidLocked(_ snapshot: [CKRecord]?) -> [CKRecord]? {
        guard let snapshot else { return nil }
        let deleted = Set(queuedDeletes)
        return snapshot.compactMap { record in
            guard !deleted.contains(record.recordID) else { return nil }
            return queuedSaves.last { $0.recordID == record.recordID } ?? record
        }
    }

    // Continuation pages are never cached as snapshots — the cursor is opaque
    // and a partial snapshot would truncate offline reads — but their full
    // records still refresh the merge baselines.
    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let response = try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        if desiredKeys == nil {
            let page = response.matchResults.compactMap { try? $0.1.get() }
            lock.withLock {
                for record in page {
                    baselines[record.recordID] = record
                    touchBaselineLocked(record.recordID)
                }
                enforceQuotasLocked()
                persistLocked()
            }
        }
        return response
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        do {
            return try await backing.save(record)
        } catch  where Self.isOffline(error) {
            let queued = Self.retainingStagedAssets(record)
            lock.withLock {
                queuedSaves.append(queued)
                persistLocked()
            }
            return record
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        do {
            try await backing.modifyRecords(saving: records, deleting: recordIDs)
        } catch  where Self.isOffline(error) {
            let queued = records.map(Self.retainingStagedAssets)
            lock.withLock {
                queuedSaves.append(contentsOf: queued)
                queuedDeletes.append(contentsOf: recordIDs)
                persistLocked()
            }
        }
    }

    // A queued save must outlive the write that staged its assets: the caller
    // is told the save succeeded and retires the staged files. Queue a copy
    // whose assets point at private duplicates in the staging directory —
    // the flush retires those once the record lands, and `sweepStagedAssets`
    // eventually collects the copies of writes that never do.
    private static func retainingStagedAssets(_ record: CKRecord) -> CKRecord {
        let staged = record.allKeys().filter { (record[$0] as? CKAsset)?.fileURL.map(EntityCoder.isStaged) == true }
        guard staged.count > 0 else { return record }
        let copy = record.copy() as! CKRecord
        for key in staged {
            guard let url = (copy[key] as? CKAsset)?.fileURL else { continue }
            let retained = EntityCoder.stagingDirectory.appendingPathComponent("offline-" + UUID().uuidString)
            guard (try? FileManager.default.copyItem(at: url, to: retained)) != nil else { continue }
            copy[key] = CKAsset(fileURL: retained)
        }
        return copy
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

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        let record = try await backing.fetchRecord(id: id)
        if let record {
            lock.withLock {
                baselines[record.recordID] = record
                touchBaselineLocked(record.recordID)
                enforceQuotasLocked()
                persistLocked()
            }
        }
        return record
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}

/// What a `ConflictResolver` decided about one conflicted queued write.
public enum ConflictResolution {
    /// Save this record instead — typically a custom merge of the two sides.
    case save(CKRecord)
    /// Keep the server copy; the queued write is dropped as landed.
    case keepServer
    /// Give up: surface the conflict in `OfflineFlushError`.
    case surface
}

/// An app-supplied policy for flush conflicts the built-in merge cannot solve.
///
/// The disjoint-field graft runs first; the resolver is only consulted when
/// the two sides moved the same field — say, to take the larger quantity, or
/// to let one side always win a field. Awaited on the flushing task, once per
/// conflicted save attempt — a decoded policy can consult the schema registry.
///
public protocol ConflictResolver: Sendable {
    /// Decides a conflict between a queued write and the moved server copy.
    ///
    /// `ancestor` is the last server copy this cache saw before the offline
    /// edit — the merge base — or nil when it was never seen or was evicted.
    /// A returned `.save` record replays under the if-unchanged policy against
    /// the `server` copy passed here; build it from `server` and re-apply the
    /// queued edits worth keeping.
    ///
    func resolve(queued: CKRecord, server: CKRecord, ancestor: CKRecord?) async -> ConflictResolution
}

/// The offline writes a flush could not replay: queued records whose server
/// copies moved in ways that overlap the offline edits.
///
/// The conflicted writes are removed from the queue — replaying them verbatim
/// could never succeed. Resolve each one by re-applying the `queued` edit on
/// top of `server`, through a fresh store update or a manual save.
///
public struct OfflineFlushError: LocalizedError {
    /// One queued write that lost to an overlapping server-side edit.
    public struct Conflict {
        public let queued: CKRecord
        public let server: CKRecord
    }

    public let conflicts: [Conflict]

    public var errorDescription: String? {
        "\(conflicts.count) offline write(s) overlap newer server edits"
    }
}
