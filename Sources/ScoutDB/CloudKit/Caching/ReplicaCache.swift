//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// A `CloudDatabase` decorator that keeps a local replica of its zones and
/// answers any query from it when the network fails.
///
/// Where `OfflineCache` replays snapshots of queries it has already seen, the
/// replica mirrors the zones' records themselves and runs the query locally —
/// filters, sorts, pagination, and projections included, through the same
/// evaluation the in-memory test double uses. The mirror feeds three ways:
/// every successful write through this database lands in it, every
/// full-fidelity `zoneChanges` pass flowing through applies its delta and,
/// when it continued from the replica's own position, advances that position
/// too (so a `SyncCoordinator` walking a zone from the start both builds the
/// mirror and keeps it fresh, with no second walk of the same feed), and
/// `refresh()` walks each zone's feed from the replica's own token for a
/// complete mirror. With a
/// `storeURL` the mirror persists across launches, written on a short delay
/// so a burst of changes costs one rewrite; `persistNow()` forces it, and a
/// write lost to a crash is re-read from the feed rather than lost.
///
/// One replica can mirror several zones — the shape of a shared database,
/// where every accepted share lives in its own zone. Configure the initial
/// set at init, register later arrivals with `add(zone:)`, or let
/// `discoverZones()` track the database feed: it registers zones with
/// activity and purges deleted ones. Zones outside the set pass through
/// untouched. The mirror holds its zones whole by design; it is a replica,
/// not a bounded cache.
///
/// Compose it outside an `OfflineCache` —
/// `ReplicaCache(backing: OfflineCache(backing: db), zoneID: zone)` — and a
/// write queued offline still reaches the mirror, so novel offline queries
/// read your writes; a flush that later merges or conflicts is corrected by
/// the next feed pass.
///
/// With `readPolicy: .localFirst` the mirror becomes the primary read path:
/// once a zone's refresh has drained its feed, reads of that zone never touch
/// the network — no round trip online, no timeout to wait out offline — and
/// freshness comes from the coordinator passes and refreshes that feed the
/// mirror. A stale local copy caught in a conditional save conflicts and
/// retries against the winner, exactly like a stale server page would.
///
public final class ReplicaCache: CloudDatabase, @unchecked Sendable {
    /// When the mirror answers reads of a replicated zone.
    public enum ReadPolicy: Sendable {
        /// Reads go to the server; the mirror answers when the network fails.
        case networkFirst
        /// Reads of a replicated zone are answered from the mirror
        /// immediately — no network round trip, no offline timeout to wait
        /// out. Freshness comes from the passes that feed the mirror: a
        /// `SyncCoordinator`, or `refresh()`. Until a zone's feed has been
        /// drained from the start — by a `refresh()`, or by the passes that
        /// fed the mirror from its own position — it behaves like
        /// `networkFirst`: a half-built mirror must not silently answer with
        /// partial results.
        case localFirst
    }

    private let backing: any CloudDatabase
    private let storeURL: URL?
    private let readPolicy: ReadPolicy
    private let fields: Set<CKRecord.FieldKey>?
    private let projectedFields: [CKRecord.FieldKey]?
    private let lock = NSLock()
    private var zones: Set<CKRecordZone.ID>
    private var mirror: [CKRecord.ID: CKRecord] = [:]
    private var scanOrder: [CKRecord]?
    private var tokens: [CKRecordZone.ID: Data] = [:]
    private var completed: Set<CKRecordZone.ID> = []
    private var databaseToken: Data?
    private var archiveStale = false
    private var archiveTask: Task<Void, Never>?
    private static let archiveDelay: Duration = .milliseconds(250)

    deinit {
        archiveTask?.cancel()
        if archiveStale {
            persistLocked()
        }
    }

    /// A `fields` list makes the replica partial.
    ///
    /// Mirrored records carry only those keys — build the list with
    /// `EntityStore.replicaFields(projecting:)` so the envelope stays in —
    /// and the mirror answers only reads it can answer honestly: projected
    /// queries whose requested keys, filters, and sorts the list covers.
    /// Everything else goes to the network as if the zone were not
    /// replicated. Record fetches are never served partially.
    ///
    public init(
        backing: any CloudDatabase, zones: [CKRecordZone.ID], storeURL: URL? = nil, readPolicy: ReadPolicy = .networkFirst,
        fields: [CKRecord.FieldKey]? = nil
    ) {
        self.backing = backing
        self.zones = Set(zones)
        self.storeURL = storeURL
        self.readPolicy = readPolicy
        self.fields = fields.map(Set.init)
        projectedFields = fields
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            restore(from: data)
        }
    }

    /// A replica of one zone; see `init(backing:zones:storeURL:readPolicy:fields:)`.
    public convenience init(
        backing: any CloudDatabase, zoneID: CKRecordZone.ID, storeURL: URL? = nil, readPolicy: ReadPolicy = .networkFirst,
        fields: [CKRecord.FieldKey]? = nil
    ) {
        self.init(backing: backing, zones: [zoneID], storeURL: storeURL, readPolicy: readPolicy, fields: fields)
    }

    /// How many records the mirror currently holds, across all zones.
    public var recordCount: Int {
        lock.withLock { mirror.count }
    }

    /// The zones the replica currently mirrors.
    public var zoneIDs: Set<CKRecordZone.ID> {
        lock.withLock { zones }
    }

    /// Whether every replicated zone's `refresh()` has drained its feed — the
    /// point from which the mirror is whole and `localFirst` serves them all.
    public var hasCompleteMirror: Bool {
        lock.withLock { zones.allSatisfy(completed.contains) }
    }

    /// Starts mirroring another zone — a newly accepted share, typically.
    ///
    /// The zone serves locally only after its first completed `refresh()`.
    ///
    public func add(zone: CKRecordZone.ID) {
        lock.withLock {
            zones.insert(zone)
            scheduleArchiveLocked()
        }
    }

    /// Tracks the database feed: registers zones with activity, purges
    /// deleted ones.
    ///
    /// The discovery step for a shared database — run it after accepting a
    /// share or on a coordinator tick, then `refresh()` to mirror what it
    /// found. Incremental: each call continues from the last one's position.
    /// Returns the zones new to the replica.
    ///
    @discardableResult public func discoverZones() async throws -> [CKRecordZone.ID] {
        let since = lock.withLock { databaseToken }
        let (changed, deleted, next) = try await backing.databaseChanges(since: since)
        return lock.withLock {
            var added: [CKRecordZone.ID] = []
            for zone in changed where !zones.contains(zone) {
                zones.insert(zone)
                added.append(zone)
            }
            for zone in deleted {
                purgeLocked(zone)
            }
            databaseToken = next ?? databaseToken
            scheduleArchiveLocked()
            return added
        }
    }

    /// Walks every replicated zone's change feed from the replica's own
    /// position until it drains, applying every batch to the mirror.
    ///
    /// The one call that guarantees a complete mirror — the passive feeding
    /// only sees what happens to flow through. Batches keep memory flat and
    /// each zone's position advances per batch, so an interrupted refresh
    /// resumes where it stopped. A zone deleted server-side is purged instead
    /// of failing the walk. Returns how many changes were applied.
    ///
    @discardableResult public func refresh(batchSize: Int = 200) async throws -> Int {
        var applied = 0
        for zone in lock.withLock({ zones }) {
            applied += try await refresh(zone: zone, batchSize: batchSize)
        }
        return applied
    }

    /// Walks one zone's change feed to the end; see `refresh(batchSize:)`.
    @discardableResult public func refresh(zone: CKRecordZone.ID, batchSize: Int = 200) async throws -> Int {
        var applied = 0
        while true {
            let since = lock.withLock { tokens[zone] }
            let changed: [CKRecord]
            let deleted: [CKRecord.ID]
            let next: Data?
            do {
                (changed, deleted, next) = try await backing.zoneChanges(
                    zoneID: zone, since: since, desiredKeys: fields.map(Array.init), resultsLimit: batchSize)
            } catch let error as CKError where error.code == .zoneNotFound {
                lock.withLock {
                    purgeLocked(zone)
                    scheduleArchiveLocked()
                }
                return applied
            }
            guard changed.count + deleted.count > 0 else {
                lock.withLock {
                    completed.insert(zone)
                    scheduleArchiveLocked()
                }
                return applied
            }
            applied += changed.count + deleted.count
            let advanced = lock.withLock { () -> Bool in
                applyLocked(changed: changed, deleted: deleted)
                let previous = tokens[zone]
                tokens[zone] = next ?? previous
                scheduleArchiveLocked()
                return next != nil && next != previous
            }
            guard advanced else {
                lock.withLock {
                    completed.insert(zone)
                    scheduleArchiveLocked()
                }
                return applied
            }
        }
    }

    private func servesLocally(_ zoneID: CKRecordZone.ID?) -> Bool {
        guard case .localFirst = readPolicy, let zoneID else { return false }
        return lock.withLock { completed.contains(zoneID) }
    }

    private func mirrors(_ zoneID: CKRecordZone.ID?) -> Bool {
        guard let zoneID else { return false }
        return lock.withLock { zones.contains(zoneID) }
    }

    private func applyLocked(changed: [CKRecord], deleted: [CKRecord.ID]) {
        if changed.count + deleted.count > 64 {
            scanOrder = nil
        }
        for record in changed {
            let trimmed = LocalQuery.project(record, keys: projectedFields)
            mirror[record.recordID] = trimmed
            placeLocked(trimmed)
        }
        for id in deleted where mirror.removeValue(forKey: id) != nil {
            removeLocked(id)
        }
    }

    private func placeLocked(_ record: CKRecord) {
        guard var order = scanOrder else { return }
        scanOrder = nil
        let name = record.recordID.recordName
        var index = Self.orderedIndex(of: name, in: order)
        var placed = false
        while index < order.count, order[index].recordID.recordName == name {
            if order[index].recordID == record.recordID {
                order[index] = record
                placed = true
                break
            }
            index += 1
        }
        if !placed {
            order.insert(record, at: index)
        }
        scanOrder = order
    }

    private func removeLocked(_ id: CKRecord.ID) {
        guard var order = scanOrder else { return }
        scanOrder = nil
        var index = Self.orderedIndex(of: id.recordName, in: order)
        while index < order.count, order[index].recordID.recordName == id.recordName {
            if order[index].recordID == id {
                order.remove(at: index)
                break
            }
            index += 1
        }
        scanOrder = order
    }

    private static func orderedIndex(of name: String, in order: [CKRecord]) -> Int {
        var low = 0
        var high = order.count
        while low < high {
            let mid = (low + high) / 2
            if order[mid].recordID.recordName < name {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func feeds(_ desiredKeys: [CKRecord.FieldKey]?) -> Bool {
        guard let desiredKeys else { return true }
        guard let fields else { return false }
        return fields.isSubset(of: desiredKeys)
    }

    private func answers(_ query: CKQuery, desiredKeys: [CKRecord.FieldKey]?) -> Bool {
        guard PredicateEvaluator.supports(query.predicate) else { return false }
        guard let fields else { return true }
        guard let desiredKeys, fields.isSuperset(of: desiredKeys) else { return false }
        guard let compared = Self.referencedKeys(of: query.predicate), fields.isSuperset(of: compared) else { return false }
        return (query.sortDescriptors ?? []).allSatisfy { descriptor in descriptor.key.map(fields.contains) ?? true }
    }

    private static func referencedKeys(of predicate: NSPredicate) -> Set<String>? {
        if let compound = predicate as? NSCompoundPredicate {
            var keys: Set<String> = []
            for sub in compound.subpredicates as? [NSPredicate] ?? [] {
                guard let inner = referencedKeys(of: sub) else { return nil }
                keys.formUnion(inner)
            }
            return keys
        }
        if let comparison = predicate as? NSComparisonPredicate {
            var keys: Set<String> = []
            for expression in [comparison.leftExpression, comparison.rightExpression] {
                guard let inner = referencedKeys(of: expression) else { return nil }
                keys.formUnion(inner)
            }
            return keys
        }
        return predicate == NSPredicate(value: true) ? [] : nil
    }

    private static func referencedKeys(of expression: NSExpression) -> Set<String>? {
        switch expression.expressionType {
        case .keyPath: return [expression.keyPath]
        case .constantValue, .evaluatedObject: return []
        case .function, .aggregate:
            var keys: Set<String> = []
            for argument in expression.arguments ?? [] {
                guard let inner = referencedKeys(of: argument) else { return nil }
                keys.formUnion(inner)
            }
            return keys
        default: return nil
        }
    }

    private func upsert(_ records: [CKRecord], deleting deleted: [CKRecord.ID] = []) {
        lock.withLock {
            let mine = records.filter { zones.contains($0.recordID.zoneID) }
            let gone = deleted.filter { zones.contains($0.zoneID) }
            guard mine.count + gone.count > 0 else { return }
            applyLocked(changed: mine, deleted: gone)
            scheduleArchiveLocked()
        }
    }

    private func purgeLocked(_ zone: CKRecordZone.ID) {
        zones.remove(zone)
        tokens[zone] = nil
        completed.remove(zone)
        mirror = mirror.filter { $0.key.zoneID != zone }
        scanOrder = nil
    }

    private func restore(from data: Data) {
        let classes = [NSDictionary.self, NSArray.self, NSString.self, NSData.self, NSNumber.self, CKRecord.self, CKRecordZone.ID.self]
        guard let root = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any] else { return }
        guard (root["fields"] as? [String]).map(Set.init) == fields else { return }
        mirror = (root["records"] as? [CKRecord] ?? []).reduce(into: [:]) { $0[$1.recordID] = $1 }
        scanOrder = nil
        zones.formUnion(root["zones"] as? [CKRecordZone.ID] ?? [])
        let tokenZones = root["tokenZones"] as? [CKRecordZone.ID] ?? []
        let tokenValues = root["tokenValues"] as? [Data] ?? []
        tokens = Dictionary(zip(tokenZones, tokenValues), uniquingKeysWith: { first, _ in first })
        completed = Set(root["completed"] as? [CKRecordZone.ID] ?? [])
        databaseToken = root["databaseToken"] as? Data
    }

    private func scheduleArchiveLocked() {
        guard storeURL != nil, !archiveStale else { return }
        archiveStale = true
        archiveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.archiveDelay)
            self?.persistNow()
        }
    }

    /// Writes the mirror to its `storeURL` now, if a change is still waiting.
    ///
    /// Changes are written on a short delay, so a caller that wants the store
    /// current — a scene heading for the background, or one about to relaunch
    /// from it — forces the write with this. Skipping it costs no data: an
    /// unwritten change is re-read from the zone's feed on the next refresh.
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
        var root: [String: Any] = [
            "records": Array(mirror.values),
            "zones": Array(zones),
            "tokenZones": Array(tokens.keys),
            "tokenValues": tokens.keys.map { tokens[$0]! },
            "completed": Array(completed),
        ]
        root["databaseToken"] = databaseToken
        root["fields"] = fields.map(Array.init)
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func scanOrderLocked() -> [CKRecord] {
        if let scanOrder { return scanOrder }
        let ordered = mirror.values.sorted { $0.recordID.recordName < $1.recordID.recordName }
        scanOrder = ordered
        return ordered
    }

    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws
        -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?)
    {
        if servesLocally(zoneID), answers(query, desiredKeys: desiredKeys) {
            return lock.withLock {
                LocalQuery.page(scanOrderLocked(), matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
            }
        }
        do {
            let response = try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
            if feeds(desiredKeys) {
                upsert(response.matchResults.compactMap { try? $0.1.get() })
            }
            return response
        } catch  where OfflineCache.isOffline(error) && mirrors(zoneID) && answers(query, desiredKeys: desiredKeys) {
            return lock.withLock {
                LocalQuery.page(scanOrderLocked(), matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
            }
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if let scan = cursor.localScan, servesLocally(scan.zoneID), answers(scan.query, desiredKeys: desiredKeys),
            let page = lock.withLock({ LocalQuery.resume(scanOrderLocked(), from: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit) })
        {
            return page
        }
        do {
            return try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        } catch {
            guard let scan = cursor.localScan, mirrors(scan.zoneID), answers(scan.query, desiredKeys: desiredKeys),
                OfflineCache.isOffline(error) || (error as? CKError)?.code == .invalidArguments,
                let page = lock.withLock({ LocalQuery.resume(scanOrderLocked(), from: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit) })
            else { throw error }
            return page
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        if fields == nil, servesLocally(id.zoneID) {
            return lock.withLock { mirror[id].map { LocalQuery.project($0, keys: nil) } }
        }
        do {
            let record = try await backing.fetchRecord(id: id)
            if let record {
                upsert([record])
            }
            return record
        } catch  where OfflineCache.isOffline(error) && mirrors(id.zoneID) && fields == nil {
            return lock.withLock { mirror[id].map { LocalQuery.project($0, keys: nil) } }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        let local = fields == nil && ids.allSatisfy { servesLocally($0.zoneID) }
        if local {
            return lock.withLock { ids.compactMap { mirror[$0].map { LocalQuery.project($0, keys: nil) } } }
        }
        do {
            let records = try await backing.fetchRecords(ids: ids)
            upsert(records)
            return records
        } catch  where OfflineCache.isOffline(error) && fields == nil && ids.allSatisfy({ mirrors($0.zoneID) }) {
            return lock.withLock { ids.compactMap { mirror[$0].map { LocalQuery.project($0, keys: nil) } } }
        }
    }

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

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        let response = try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        if feeds(desiredKeys) {
            upsert(response.changed, deleting: response.deleted)
            adopt(response.token, of: zoneID, continuing: token, drained: resultsLimit == nil || response.changed.count + response.deleted.count == 0)
        }
        return response
    }

    private func adopt(_ next: Data?, of zoneID: CKRecordZone.ID, continuing token: Data?, drained: Bool) {
        lock.withLock {
            guard zones.contains(zoneID), tokens[zoneID] == token else { return }
            if let next {
                tokens[zoneID] = next
            }
            if drained {
                completed.insert(zoneID)
            }
            scheduleArchiveLocked()
        }
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

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}
