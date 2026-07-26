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
/// network fails — stale by definition, but present. A read by ID is served the
/// same way from the merge baselines the cache already keeps, so a
/// read-modify-write reaches its record offline; an ID no baseline covers stays
/// failed rather than answering "the server has no such record". Plain writes
/// made offline are queued and reported successful; `flush()` replays them once
/// the network is back, and record uuids make the replay idempotent. The replay is
/// conflict-aware: every save runs under the if-unchanged policy, offline edits
/// are grafted onto a server record that moved when the two sides touched
/// disjoint fields, and overlapping edits surface as `OfflineFlushError`
/// instead of overwriting the server. Queued writes are not visible to reads
/// until they flush, and conditional (CAS) saves are never queued — deferring
/// a compare-and-swap would discard its comparison.
///
public final class OfflineCache: CloudDatabase, @unchecked Sendable {
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
    private var baselines: [CKRecord.ID: CKRecord] = [:]
    private let snapshotLimit: Int
    private let baselineLimit: Int
    private var conflictResolver: (any ConflictResolver)?
    private var snapshotUsage: [String: Int64] = [:]
    private var baselineUsage: [CKRecord.ID: Int64] = [:]
    private var clock: Int64 = 0
    private var archiveStale = false
    private var archiveTask: Task<Void, Never>?
    private static let archiveDelay: Duration = .milliseconds(250)

    deinit {
        archiveTask?.cancel()
        if archiveStale {
            persistLocked()
        }
    }

    /// With a `storeURL`, snapshots and the write queue persist across launches,
    /// and init restores them.
    ///
    /// Queueing or replaying a write archives the queue immediately: the caller
    /// was told an offline write succeeded, so it must survive a crash. The queue
    /// lives in its own small file next to `storeURL`, so that synchronous write
    /// never re-serializes the snapshots and baselines; those are archived to
    /// `storeURL` on a short delay instead, since every read refreshes them and
    /// losing the tail costs freshness, not correctness — `persistNow()` forces
    /// one. Either way the write is best-effort; a failed one costs freshness,
    /// not correctness.
    ///
    /// The quotas keep the cache bounded: about `snapshotLimit` query
    /// snapshots and `baselineLimit` merge baselines, evicted least-recently
    /// used. Eviction runs in batches once a store overflows its limit by ten
    /// percent, shedding the overflow down to the limit in one ordering pass,
    /// so a read-heavy steady state does not pay an eviction sort per fetch.
    /// An evicted snapshot costs offline coverage of that query; an evicted
    /// baseline degrades a conflicting flush from a merge to a surfaced
    /// conflict — never correctness.
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
        if let queueURL {
            if let data = try? Data(contentsOf: queueURL) {
                pending = Self.decodeOps(from: data) ?? pending
            } else if !pending.isEmpty {
                lock.withLock { persistQueueLocked() }
            }
        }
    }

    private var queueURL: URL? {
        storeURL?.appendingPathExtension("queue")
    }

    private func enforceQuotasLocked() {
        Self.evict(&snapshots, usage: &snapshotUsage, limit: snapshotLimit)
        Self.evict(&baselines, usage: &baselineUsage, limit: baselineLimit)
    }

    static func evict<Key: Hashable, Value>(_ store: inout [Key: Value], usage: inout [Key: Int64], limit: Int) {
        guard store.count > limit + limit / 10 else { return }
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

    private static let archiveClasses = [NSDictionary.self, NSArray.self, NSString.self, CKRecord.self, CKRecord.ID.self]

    private func restore(from data: Data) {
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: Self.archiveClasses, from: data) as? [String: Any] else { return }
        snapshots = root["snapshots"] as? [String: [CKRecord]] ?? [:]
        if let ops = root["ops"] as? [[String: Any]] {
            pending = Self.decodeOps(ops)
        } else {
            let saves = (root["saves"] as? [CKRecord] ?? []).map(PendingWrite.save)
            let deletes = (root["deletes"] as? [CKRecord.ID] ?? []).map(PendingWrite.delete)
            pending = saves + deletes
        }
        baselines = (root["baselines"] as? [CKRecord] ?? []).reduce(into: [:]) { $0[$1.recordID] = $1 }
    }

    private static func decodeOps(from data: Data) -> [PendingWrite]? {
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archiveClasses, from: data) as? [String: Any],
            let ops = root["ops"] as? [[String: Any]]
        else { return nil }
        return decodeOps(ops)
    }

    private static func decodeOps(_ ops: [[String: Any]]) -> [PendingWrite] {
        ops.compactMap { entry in
            switch entry["t"] as? String {
            case "s": return (entry["r"] as? CKRecord).map(PendingWrite.save)
            case "d": return (entry["r"] as? CKRecord.ID).map(PendingWrite.delete)
            default: return nil
            }
        }
    }

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

    private func persistLocked() {
        archiveStale = false
        guard let storeURL else { return }
        let root: [String: Any] = [
            "snapshots": snapshots, "baselines": Array(baselines.values),
        ]
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func persistQueueLocked() {
        guard let queueURL else { return }
        let ops: [[String: Any]] = pending.map { op in
            switch op {
            case .save(let record): return ["t": "s", "r": record]
            case .delete(let id): return ["t": "d", "r": id]
            }
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: ["ops": ops], requiringSecureCoding: true) else { return }
        try? data.write(to: queueURL, options: .atomic)
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
            persistQueueLocked()
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
    /// Saves and deletions both replay in batches, and a re-attempted merge
    /// rejoins the batch rather than going out on its own, so a long offline
    /// stretch costs a request per batch and merge round — not one per record.
    /// A batch the server calls too large is bisected until it fits.
    ///
    @discardableResult public func flush() async throws -> Int {
        let snapshot = lock.withLock { pending }
        guard !snapshot.isEmpty else { return 0 }

        var lastIndex: [CKRecord.ID: Int] = [:]
        for (index, op) in snapshot.enumerated() { lastIndex[op.recordID] = index }
        let effective = snapshot.enumerated().filter { lastIndex[$0.element.recordID] == $0.offset }.map(\.element)
        let superseded = snapshot.enumerated()
            .filter { lastIndex[$0.element.recordID] != $0.offset }
            .compactMap { op -> CKRecord? in
                guard case .save(let record) = op.element else { return nil }
                return record
            }
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
            var contested: [(record: CKRecord, server: CKRecord)] = []
            for chunk in effectiveSaves.chunked(into: Self.maxBatchSize) {
                for (record, result) in try await submit(chunk) {
                    let id = record.recordID
                    do {
                        _ = try result.get()
                        landedCount += 1
                        EntityCoder.discardStagedAssets(in: [record])
                    } catch  where Self.isOffline(error) {
                        throw error
                    } catch {
                        guard let server = Self.conflictingServerRecord(in: error) else {
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
            let pushed = await push(contested)
            for (record, outcome) in pushed.outcomes {
                switch outcome {
                case .landed:
                    landedCount += 1
                    EntityCoder.discardStagedAssets(in: [record])
                case .conflict(let server):
                    conflicts.append(OfflineFlushError.Conflict(queued: record, server: server))
                case .failure(let error):
                    failures.append(OfflineFlushError.Failure(recordID: record.recordID, error: error))
                    EntityCoder.discardStagedAssets(in: [record])
                }
                resolved.insert(record.recordID)
            }
            if let failure = pushed.transportFailure { throw failure }
            for chunk in effectiveDeletes.chunked(into: Self.maxBatchSize) {
                let rejected = try await submit(deleting: chunk)
                landedCount += chunk.count - rejected.count
                failures += rejected
                resolved.formUnion(chunk)
            }
        } catch {
            transportFailure = error
        }

        EntityCoder.discardStagedAssets(in: superseded.filter { resolved.contains($0.recordID) })
        dequeue(snapshot.filter { resolved.contains($0.recordID) })

        if let transportFailure { throw transportFailure }
        guard conflicts.isEmpty, failures.isEmpty else {
            throw OfflineFlushError(conflicts: conflicts, failures: failures)
        }
        return landedCount
    }

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
            persistQueueLocked()
        }
    }

    private enum PushOutcome {
        case landed
        case conflict(CKRecord)
        case failure(any Error)
    }

    private func push(_ contested: [(record: CKRecord, server: CKRecord)]) async -> (
        outcomes: [(record: CKRecord, outcome: PushOutcome)], transportFailure: (any Error)?
    ) {
        var outcomes: [CKRecord.ID: PushOutcome] = [:]
        var open = contested.map { (record: $0.record, server: $0.server, retries: 3) }
        var transportFailure: (any Error)?
        while !open.isEmpty, transportFailure == nil {
            var attempts: [CKRecord] = []
            var origins: [CKRecord.ID: (record: CKRecord, retries: Int)] = [:]
            for entry in open {
                let id = entry.record.recordID
                let retries = entry.retries - 1
                guard retries > 0 else {
                    outcomes[id] = .conflict(entry.server)
                    continue
                }
                let attempt: CKRecord
                if let merged = graft(entry.record, onto: entry.server) {
                    attempt = merged
                } else {
                    switch await resolve(entry.record, against: entry.server) {
                    case .save(let resolved):
                        attempt = resolved
                    case .keepServer:
                        outcomes[id] = .landed
                        continue
                    case .surface:
                        outcomes[id] = .conflict(entry.server)
                        continue
                    }
                }
                attempts.append(attempt)
                origins[id] = (entry.record, retries)
            }
            open = []
            var replayed: [(record: CKRecord, result: Result<CKRecord, any Error>)] = []
            for chunk in attempts.chunked(into: Self.maxBatchSize) {
                do {
                    replayed += try await submit(chunk)
                } catch {
                    transportFailure = error
                    break
                }
            }
            for (attempt, result) in replayed {
                let id = attempt.recordID
                guard let origin = origins[id] else { continue }
                do {
                    _ = try result.get()
                    outcomes[id] = .landed
                } catch  where Self.isOffline(error) {
                    transportFailure = transportFailure ?? error
                } catch {
                    guard let server = Self.conflictingServerRecord(in: error) else {
                        outcomes[id] = .failure(error)
                        continue
                    }
                    open.append((origin.record, server, origin.retries))
                }
            }
        }
        return (contested.compactMap { entry in outcomes[entry.record.recordID].map { (entry.record, $0) } }, transportFailure)
    }

    private func submit(_ records: [CKRecord]) async throws -> [(record: CKRecord, result: Result<CKRecord, any Error>)] {
        guard records.count > 0 else { return [] }
        do {
            let batch = try await backing.saveIfUnchanged(records)
            let byID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
            return batch.compactMap { entry in byID[entry.0].map { ($0, entry.1) } }
        } catch  where Self.isOffline(error) {
            throw error
        } catch  where Self.exceedsBatchLimit(error) && records.count > 1 {
            let half = records.count / 2
            return try await submit(Array(records[..<half])) + submit(Array(records[half...]))
        } catch {
            return records.map { ($0, .failure(error)) }
        }
    }

    private func submit(deleting ids: [CKRecord.ID]) async throws -> [OfflineFlushError.Failure] {
        guard ids.count > 0 else { return [] }
        do {
            try await backing.modifyRecords(saving: [], deleting: ids)
            return []
        } catch  where Self.isOffline(error) {
            throw error
        } catch  where Self.exceedsBatchLimit(error) && ids.count > 1 {
            let half = ids.count / 2
            return try await submit(deleting: Array(ids[..<half])) + submit(deleting: Array(ids[half...]))
        } catch {
            return ids.map { OfflineFlushError.Failure(recordID: $0, error: error) }
        }
    }

    private static func exceedsBatchLimit(_ error: any Error) -> Bool {
        (error as? CKError)?.code == .limitExceeded
    }

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
        RecordConflictError(error)?.serverRecord
    }

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
        if let tag = server.recordVersionTag {
            merged.overrideChangeTag(tag)
        }
        for (key, value) in mine {
            merged[key] = value
        }
        return merged
    }

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

    private static let offlineCodes: Set<CKError.Code> = [
        .networkUnavailable, .networkFailure, .serviceUnavailable, .notAuthenticated, .accountTemporarilyUnavailable,
    ]

    static func isOffline(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        for _ in 0..<4 {
            guard let error = current else { return false }
            if error is URLError || error is RequestTimeoutError { return true }
            if let code = (error as? CKError)?.code, offlineCodes.contains(code) { return true }
            current = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return false
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
                if desiredKeys == nil {
                    for record in page {
                        baselines[record.recordID] = record
                        touchBaselineLocked(record.recordID)
                    }
                }
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

    private func overlaidLocked(_ snapshot: [CKRecord]?) -> [CKRecord]? {
        guard let snapshot else { return nil }
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

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let response = try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        if desiredKeys == nil {
            let page = response.matchResults.compactMap { try? $0.1.get() }
            lock.withLock { rememberLocked(page) }
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
                persistQueueLocked()
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
                persistQueueLocked()
            }
        }
    }

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
        do {
            let record = try await backing.fetchRecord(id: id)
            if let record {
                lock.withLock { rememberLocked([record]) }
            }
            return record
        } catch  where Self.isOffline(error) {
            switch lock.withLock({ cachedLocked(id) }) {
            case .record(let cached): return cached
            case .deleted: return nil
            case .unknown: throw error
            }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        do {
            let records = try await backing.fetchRecords(ids: ids)
            guard records.count > 0 else { return records }
            lock.withLock { rememberLocked(records) }
            return records
        } catch  where Self.isOffline(error) {
            let cached = lock.withLock { () -> [CKRecord]? in
                var known: [CKRecord] = []
                for id in ids {
                    switch cachedLocked(id) {
                    case .record(let record): known.append(record)
                    case .deleted: continue
                    case .unknown: return nil
                    }
                }
                return known
            }
            guard let cached else { throw error }
            return cached
        }
    }

    private enum CachedRecord {
        case record(CKRecord)
        case deleted
        case unknown
    }

    private func cachedLocked(_ id: CKRecord.ID) -> CachedRecord {
        switch pending.last(where: { $0.recordID == id }) {
        case .delete:
            return .deleted
        case .save(let queued):
            return .record(queued.copy() as! CKRecord)
        case nil:
            guard let baseline = baselines[id] else { return .unknown }
            touchBaselineLocked(id)
            return .record(baseline.copy() as! CKRecord)
        }
    }

    private func rememberLocked(_ records: [CKRecord]) {
        for record in records {
            baselines[record.recordID] = record
            touchBaselineLocked(record.recordID)
        }
        enforceQuotasLocked()
        scheduleArchiveLocked()
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
