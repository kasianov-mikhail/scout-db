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

    /// With a `storeURL`, snapshots and the write queue persist across launches:
    /// every mutation archives the state to the file (best-effort — a failed
    /// write costs freshness, not correctness), and init restores it.
    public init(backing: any CloudDatabase, storeURL: URL? = nil) {
        self.backing = backing
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            restore(from: data)
        }
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

    /// The writes waiting for `flush`, in arrival order.
    public var pendingWrites: Int {
        lock.withLock { queuedSaves.count + queuedDeletes.count }
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
        var landed: Set<Int> = []
        do {
            for (index, record) in saves.enumerated() {
                if let conflict = try await push(record) {
                    conflicts.append(conflict)
                } else {
                    landed.insert(index)
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
            dequeue(saveIndices: landed, deletes: 0)
            throw error
        }
        // Conflicted saves leave the queue too: they are handed to the caller,
        // and replaying them verbatim could never succeed.
        dequeue(saveIndices: Set(saves.indices), deletes: deletes.count)
        guard conflicts.isEmpty else { throw OfflineFlushError(conflicts: conflicts) }
        return saves.count + deletes.count
    }

    private func dequeue(saveIndices: Set<Int>, deletes: Int) {
        lock.withLock {
            var index = -1
            queuedSaves.removeAll { _ in
                index += 1
                return saveIndices.contains(index)
            }
            queuedDeletes.removeFirst(deletes)
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
                guard retries > 0, let merged = graft(record, onto: server) else {
                    return OfflineFlushError.Conflict(queued: record, server: server)
                }
                attempt = merged
            }
        }
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
        guard let ancestor = lock.withLock({ baselines[queued.recordID] }) else { return nil }
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
                    }
                }
                // Only a complete response can stand in for the query later; a first
                // page served offline would silently truncate the result set.
                if response.queryCursor == nil {
                    snapshots[key] = page
                }
                if desiredKeys == nil || response.queryCursor == nil {
                    persistLocked()
                }
            }
            return response
        } catch  where Self.isOffline(error) {
            guard let cached = lock.withLock({ overlaidLocked(snapshots[key]) }) else { throw error }
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
                }
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
                persistLocked()
            }
        }
        return record
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?) async throws -> (changed: [CKRecord], deleted: [CKRecord.ID], token: Data?) {
        try await backing.zoneChanges(zoneID: zoneID, since: token)
    }
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
