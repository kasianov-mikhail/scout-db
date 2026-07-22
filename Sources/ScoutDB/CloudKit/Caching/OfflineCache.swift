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
    // One offline write in the replay log. Saves and deletes share a single
    // ordered queue so their arrival order survives — a delete followed by a
    // recreate of the same id, or the reverse, must replay in the order it
    // happened, not saves-then-deletes.
    private enum PendingWrite {
        case save(CKRecord)
        case delete(CKRecord.ID)

        var recordID: CKRecord.ID {
            switch self {
            case .save(let record): return record.recordID
            case .delete(let id): return id
            }
        }
    }

    private let backing: any CloudDatabase
    private let storeURL: URL?
    private let lock = NSLock()
    private var snapshots: [String: [CKRecord]] = [:]
    private var pending: [PendingWrite] = []
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
    // Whether the archive is behind the freshness held in memory, and the
    // delayed write that will settle it.
    private var archiveStale = false
    private var archiveTask: Task<Void, Never>?
    private static let archiveDelay: Duration = .milliseconds(250)

    deinit {
        archiveTask?.cancel()
        // The cache is going away with freshness the archive never saw; this is
        // the last chance to hand it over.
        if archiveStale {
            persistLocked()
        }
    }

    /// With a `storeURL`, snapshots and the write queue persist across launches,
    /// and init restores them.
    ///
    /// Queueing or replaying a write archives the state immediately: the caller
    /// was told an offline write succeeded, so it must survive a crash. Snapshot
    /// and baseline refreshes are archived on a short delay instead, since every
    /// read produces them and losing the tail costs freshness, not correctness —
    /// `persistNow()` forces one. Either way the write is best-effort; a failed
    /// one costs freshness, not correctness.
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
        Self.evict(&snapshots, usage: &snapshotUsage, limit: snapshotLimit)
        Self.evict(&baselines, usage: &baselineUsage, limit: baselineLimit)
    }

    // Drops the least recently used entries until the store fits its quota,
    // ordering the keys once instead of rescanning every entry for a fresh
    // minimum per victim. The rescan cost most on the restore path, where an
    // oversized archive sheds its whole overflow at once and every restored
    // entry ties at the oldest usage.
    static func evict<Key: Hashable, Value>(_ store: inout [Key: Value], usage: inout [Key: Int64], limit: Int) {
        guard store.count > limit else { return }
        for victim in store.keys.sorted(by: { usage[$0] ?? 0 < usage[$1] ?? 0 }).prefix(store.count - limit) {
            store[victim] = nil
            usage[victim] = nil
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
        if let ops = root["ops"] as? [[String: Any]] {
            pending = ops.compactMap { entry in
                switch entry["t"] as? String {
                case "s": return (entry["r"] as? CKRecord).map(PendingWrite.save)
                case "d": return (entry["r"] as? CKRecord.ID).map(PendingWrite.delete)
                default: return nil
                }
            }
        } else {
            // A queue archived before the ordered log: saves replayed first, then
            // deletes, so restore it in that order.
            let saves = (root["saves"] as? [CKRecord] ?? []).map(PendingWrite.save)
            let deletes = (root["deletes"] as? [CKRecord.ID] ?? []).map(PendingWrite.delete)
            pending = saves + deletes
        }
        baselines = (root["baselines"] as? [CKRecord] ?? []).reduce(into: [:]) { $0[$1.recordID] = $1 }
    }

    // Marks the archive stale and lets one delayed write settle it, instead of
    // rewriting the whole file inline.
    //
    // Only freshness rides this path. Every read refreshes snapshots and merge
    // baselines, and each rewrite serializes the entire cache under the lock, so
    // a burst of reads otherwise costs a burst of full rewrites. Losing the tail
    // of that costs staleness, nothing more. The write queue does not come here:
    // a queued write was reported to its caller as successful, so it is archived
    // synchronously and must survive a crash.
    private func scheduleArchiveLocked() {
        guard storeURL != nil, !archiveStale else { return }
        archiveStale = true
        archiveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.archiveDelay)
            self?.persistNow()
        }
    }

    /// Archives the cache now, if a freshness update is still waiting.
    ///
    /// Snapshot and baseline refreshes are written on a short delay, so a caller
    /// that cannot afford to lose them — a scene heading for the background —
    /// forces the write with this. Queued offline writes never need it; they are
    /// archived as they are made.
    ///
    public func persistNow() {
        lock.withLock {
            guard archiveStale else { return }
            persistLocked()
        }
    }

    // Callers hold the lock; the archive is a full rewrite, small by design
    // (complete query snapshots plus the pending queue). It carries whatever
    // freshness was waiting, so the scheduled write has nothing left to do.
    private func persistLocked() {
        archiveStale = false
        guard let storeURL else { return }
        let ops: [[String: Any]] = pending.map { op in
            switch op {
            case .save(let record): return ["t": "s", "r": record]
            case .delete(let id): return ["t": "d", "r": id]
            }
        }
        let root: [String: Any] = [
            "snapshots": snapshots, "ops": ops, "baselines": Array(baselines.values),
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
        lock.withLock { pending.count }
    }

    /// One write sitting in the offline queue.
    public enum QueuedWrite: @unchecked Sendable {
        /// A record save awaiting replay; the record is a defensive copy.
        case save(CKRecord)
        /// A deletion awaiting replay.
        case delete(CKRecord.ID)
    }

    /// The queued writes awaiting `flush`, in arrival order.
    ///
    /// The records are defensive copies — mutating one does not edit the queue.
    /// Use `discardQueuedWrites(for:)` to drop an entry that should not replay.
    ///
    public var queuedWrites: [QueuedWrite] {
        lock.withLock {
            pending.map { op in
                switch op {
                case .save(let record): return .save(record.copy() as! CKRecord)
                case .delete(let id): return .delete(id)
                }
            }
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
            let before = pending.count
            let dropped = pending.compactMap { op -> CKRecord? in
                guard case .save(let record) = op, record.recordID == id else { return nil }
                return record
            }
            pending.removeAll { $0.recordID == id }
            let removed = before - pending.count
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
        let snapshot = lock.withLock { pending }
        guard !snapshot.isEmpty else { return 0 }

        // The net offline intent per record is its last queued op — exactly what
        // offline reads surfaced through `overlaidLocked`. Replay only that: an
        // earlier save superseded by a later one, or a delete cancelled by a
        // later recreate, never uploads. This collapses repeated edits (which
        // would otherwise conflict against their own predecessor and be lost)
        // and honors save/delete order for a reused record id.
        var lastIndex: [CKRecord.ID: Int] = [:]
        for (index, op) in snapshot.enumerated() { lastIndex[op.recordID] = index }
        let effective = snapshot.enumerated().filter { lastIndex[$0.element.recordID] == $0.offset }.map(\.element)
        let superseded = snapshot.enumerated()
            .filter { lastIndex[$0.element.recordID] != $0.offset }
            .compactMap { op -> CKRecord? in
                guard case .save(let record) = op.element else { return nil }
                return record
            }
        // Only one op survives per record id, so effective saves and deletes
        // target disjoint records — deletes can batch, order between records
        // does not matter.
        let effectiveSaves = effective.compactMap { op -> CKRecord? in
            guard case .save(let record) = op else { return nil }
            return record
        }
        let effectiveDeletes = effective.compactMap { op -> CKRecord.ID? in
            guard case .delete(let id) = op else { return nil }
            return id
        }

        var conflicts: [OfflineFlushError.Conflict] = []
        var failures: [OfflineFlushError.Failure] = []
        var resolved = Set<CKRecord.ID>()
        var landedCount = 0
        var transportFailure: (any Error)?
        do {
            // The queue replays as conditional batches; only the records that
            // actually lost a race need the per-record merge below, so an
            // uncontended flush costs one request per chunk rather than one per
            // record.
            // The records the batch could not settle, each with the winning
            // server record when the batch named one.
            var contested: [(record: CKRecord, server: CKRecord?)] = []
            for chunk in effectiveSaves.chunked(into: Self.maxBatchSize) {
                let batch: [(CKRecord.ID, Result<CKRecord, any Error>)]
                do {
                    batch = try await backing.saveIfUnchanged(chunk)
                } catch  where Self.isOffline(error) {
                    throw error
                } catch {
                    // The call failed as a whole, so it cannot say which record
                    // was at fault. Replay the chunk one record at a time, which
                    // attributes the failure instead of blaming all of them.
                    contested += chunk.map { ($0, nil) }
                    continue
                }
                let byID = Dictionary(chunk.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
                for (id, result) in batch {
                    guard let record = byID[id] else { continue }
                    do {
                        _ = try result.get()
                        landedCount += 1
                        EntityCoder.discardStagedAssets(in: [record])
                    } catch  where Self.isOffline(error) {
                        throw error
                    } catch {
                        guard let server = Self.conflictingServerRecord(in: error) else {
                            // A permanent per-record failure (permission, quota,
                            // invalid argument) will never land on replay. Surface
                            // it and drop the write instead of wedging the whole
                            // queue behind it forever.
                            failures.append(OfflineFlushError.Failure(recordID: id, error: error))
                            EntityCoder.discardStagedAssets(in: [record])
                            resolved.insert(id)
                            continue
                        }
                        contested.append((record, server))
                        continue
                    }
                    resolved.insert(id)
                }
            }
            for (record, server) in contested {
                do {
                    // The batch already surfaced the winning record, so the merge
                    // starts from it instead of re-attempting a save that would
                    // lose the same race again.
                    if let conflict = try await push(record, losingTo: server) {
                        // Handed to the caller; its staged assets stay in case the
                        // caller re-saves the record.
                        conflicts.append(conflict)
                    } else {
                        landedCount += 1
                        EntityCoder.discardStagedAssets(in: [record])
                    }
                } catch  where Self.isOffline(error) {
                    throw error
                } catch {
                    failures.append(OfflineFlushError.Failure(recordID: record.recordID, error: error))
                    EntityCoder.discardStagedAssets(in: [record])
                }
                resolved.insert(record.recordID)
            }
            if !effectiveDeletes.isEmpty {
                do {
                    try await backing.modifyRecords(saving: [], deleting: effectiveDeletes)
                    landedCount += effectiveDeletes.count
                } catch  where Self.isOffline(error) {
                    throw error
                } catch {
                    for id in effectiveDeletes {
                        failures.append(OfflineFlushError.Failure(recordID: id, error: error))
                    }
                }
                for id in effectiveDeletes { resolved.insert(id) }
            }
        } catch {
            // A transport failure stops the replay; keep every record not yet
            // resolved queued for the next attempt.
            transportFailure = error
        }

        // Drop the resolved records (landed, conflicted, or permanently failed)
        // and retire the staged assets of their superseded copies. Records left
        // unresolved by a transport failure stay queued verbatim.
        EntityCoder.discardStagedAssets(in: superseded.filter { resolved.contains($0.recordID) })
        dequeue(snapshot.filter { resolved.contains($0.recordID) })

        if let transportFailure { throw transportFailure }
        guard conflicts.isEmpty, failures.isEmpty else {
            throw OfflineFlushError(conflicts: conflicts, failures: failures)
        }
        return landedCount
    }

    // Removes the given ops from the queue — by identity for saves and one
    // occurrence per id for deletes, so a concurrent enqueue (a fresh offline
    // write of the same record made mid-flush) is never dropped by mistake.
    private func dequeue(_ ops: [PendingWrite]) {
        lock.withLock {
            let replayedSaves = Set(
                ops.compactMap { op -> ObjectIdentifier? in
                    guard case .save(let record) = op else { return nil }
                    return ObjectIdentifier(record)
                })
            var remainingDeletes = ops.compactMap { op -> CKRecord.ID? in
                guard case .delete(let id) = op else { return nil }
                return id
            }
            pending.removeAll { op in
                switch op {
                case .save(let record):
                    return replayedSaves.contains(ObjectIdentifier(record))
                case .delete(let id):
                    guard let index = remainingDeletes.firstIndex(of: id) else { return false }
                    remainingDeletes.remove(at: index)
                    return true
                }
            }
            persistLocked()
        }
    }

    // Replays one queued save under the if-unchanged policy, re-merging against
    // the moving server record a bounded number of times. Returns the conflict
    // when the edits overlap; transport and other non-conflict errors throw.
    //
    // `losingTo` carries the winning record of a race the caller already ran, so
    // the merge starts there rather than re-attempting a save known to conflict.
    private func push(_ record: CKRecord, losingTo initial: CKRecord? = nil) async throws -> OfflineFlushError.Conflict? {
        var attempt = record
        var pending = initial
        var retries = 3
        while true {
            let server: CKRecord
            if let known = pending {
                server = known
                pending = nil
            } else {
                do {
                    for (_, result) in try await backing.saveIfUnchanged([attempt]) {
                        _ = try result.get()
                    }
                    return nil
                } catch {
                    guard let conflicting = Self.conflictingServerRecord(in: error) else { throw error }
                    server = conflicting
                }
            }
            retries -= 1
            guard retries > 0 else { return OfflineFlushError.Conflict(queued: record, server: server) }
            if let merged = graft(record, onto: server) {
                attempt = merged
                continue
            }
            switch await resolve(record, against: server) {
            case .save(let resolved):
                attempt = resolved
            case .keepServer:
                return nil
            case .surface:
                return OfflineFlushError.Conflict(queued: record, server: server)
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
                    scheduleArchiveLocked()
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
        // The net effect on a record is its last queued op: a later save replaces
        // it, a later delete drops it, and a recreate after a delete brings it
        // back — read-your-updates, tombstones included.
        var lastOp: [CKRecord.ID: PendingWrite] = [:]
        for op in pending { lastOp[op.recordID] = op }
        return snapshot.compactMap { record in
            switch lastOp[record.recordID] {
            case .delete: return nil
            case .save(let queued): return queued
            case nil: return record
            }
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
                scheduleArchiveLocked()
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
                pending.append(.save(queued))
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
                pending.append(contentsOf: queued.map(PendingWrite.save))
                pending.append(contentsOf: recordIDs.map(PendingWrite.delete))
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
                scheduleArchiveLocked()
            }
        }
        return record
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        let records = try await backing.fetchRecords(ids: ids)
        guard records.count > 0 else { return records }
        lock.withLock {
            // Whole records straight from the server: exactly what a merge
            // baseline is, like the single-record fetch above.
            for record in records {
                baselines[record.recordID] = record
                touchBaselineLocked(record.recordID)
            }
            enforceQuotasLocked()
            scheduleArchiveLocked()
        }
        return records
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

/// The offline writes a flush could not complete: queued records whose server
/// copies moved in ways that overlap the offline edits (`conflicts`), and
/// queued writes the server rejected outright (`failures`).
///
/// Both leave the queue — replaying them verbatim could never succeed. Resolve
/// a conflict by re-applying the `queued` edit on top of `server`, through a
/// fresh store update or a manual save; a failure carries the server's own
/// error for its record.
///
public struct OfflineFlushError: LocalizedError {
    /// One queued write that lost to an overlapping server-side edit.
    public struct Conflict: @unchecked Sendable {
        public let queued: CKRecord
        public let server: CKRecord
    }

    /// One queued write the server rejected for a non-conflict reason — a
    /// permission, quota, or invalid-argument error that no replay would fix.
    public struct Failure: @unchecked Sendable {
        public let recordID: CKRecord.ID
        public let error: any Error
    }

    public let conflicts: [Conflict]
    public let failures: [Failure]

    public init(conflicts: [Conflict], failures: [Failure] = []) {
        self.conflicts = conflicts
        self.failures = failures
    }

    public var errorDescription: String? {
        var parts: [String] = []
        if !conflicts.isEmpty { parts.append("\(conflicts.count) offline write(s) overlap newer server edits") }
        if !failures.isEmpty { parts.append("\(failures.count) offline write(s) were rejected by the server") }
        return parts.joined(separator: "; ")
    }
}
