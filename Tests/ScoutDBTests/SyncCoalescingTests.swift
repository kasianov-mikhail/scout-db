//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Sync coalescing")
struct SyncCoalescingTests {
    @Test("A burst of concurrent syncs coalesces into at most two passes")
    func burstCoalesces() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let gated = GatedDatabase(backing: database)
        let store = EntityStore(database: gated, registry: registry, zoneID: CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName))
        try await store.ensureZone()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let coordinator = SyncCoordinator(store: store)

        // Hold the first pass open at the zone fetch, then raise a burst: every
        // caller that arrives while it runs must share one trailing pass.
        let first = Task { try await coordinator.sync() }
        await gated.gate.awaitArrival()
        let burst = (0..<4).map { _ in Task { try await coordinator.sync() } }
        try? await Task.sleep(for: .milliseconds(50))
        await gated.gate.open()

        #expect(try await first.value.records.map(\.uuid) == ["p-1"])
        for task in burst {
            // The shared trailing pass ran after the first advanced the token,
            // so the burst sees an empty delta rather than p-1 five times over.
            #expect(try await task.value.records.isEmpty)
        }
        #expect(await gated.gate.calls == 2)

        // Sequential syncs stay uncoalesced — each request its own pass.
        _ = try await coordinator.sync()
        #expect(await gated.gate.calls == 3)
    }
}

@Suite("Sync lifecycle")
struct SyncLifecycleTests {
    @Test("start runs periodic passes and stop halts them")
    func startStopLifecycle() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let gated = GatedDatabase(backing: database)
        let store = EntityStore(database: gated, registry: registry, zoneID: CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName))
        try await store.ensureZone()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        await gated.gate.open()

        let seen = Seen()
        let coordinator = SyncCoordinator(store: store)
        #expect(!coordinator.isRunning)
        coordinator.start(every: .milliseconds(20)) { delta in
            seen.add(delta.records.map(\.uuid))
        }
        coordinator.start(every: .milliseconds(20))  // idempotent: no second runner
        #expect(coordinator.isRunning)

        // The immediate first pass delivers p-1; a later write reaches a
        // periodic pass without any push.
        try await poll { seen.uuids.contains("p-1") }
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        try await poll { seen.uuids.contains("p-2") }

        // After stop, the pass counter settles for good.
        coordinator.stop()
        #expect(!coordinator.isRunning)
        try? await Task.sleep(for: .milliseconds(60))
        let settled = await gated.gate.calls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await gated.gate.calls == settled)
    }

    @Test("A projecting coordinator pulls trimmed records")
    func projectedCoordinator() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let store = EntityStore(database: database, registry: registry, zoneID: CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName))
        try await store.ensureZone()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let coordinator = SyncCoordinator(store: store, projecting: [SyncProjection(entity: "purchase", fields: ["quantity"])])
        let delta = try await coordinator.sync()
        let record = try #require(delta.records.first)
        #expect(record.values["quantity"] == .int(3))
        #expect(record.values["product_id"] == nil)
        #expect(record.values["comment"] == nil)
    }

    @Test("A batched coordinator reports progress and combines the batches")
    func batchedCoordinator() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let store = EntityStore(database: database, registry: registry, zoneID: CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName))
        try await store.ensureZone()
        for index in 0..<5 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }

        // Progress ticks with the running count after every batch; the caller
        // still receives the whole pass as one delta.
        let counts = Seen()
        let coordinator = SyncCoordinator(store: store, batchSize: 2, onProgress: { counts.add(["\($0)"]) })
        let delta = try await coordinator.sync()
        #expect(delta.records.count == 5)
        #expect(counts.uuids == ["2", "4", "5"])

        // The next pass starts from the combined token: nothing new, no ticks.
        #expect(try await coordinator.sync().records.isEmpty)
        #expect(counts.uuids == ["2", "4", "5"])
    }

    @Test("Failures nobody awaits reach onError")
    func onErrorSurfaces() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let cache = OfflineCache(backing: database)
        let store = EntityStore(
            database: cache, registry: SchemaRegistry(database: cache), zoneID: CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName))
        try await store.ensureZone()
        let errors = Seen()
        let coordinator = SyncCoordinator(
            store: store, cache: cache,
            onError: { errors.add([($0 as? CKError)?.code == .notAuthenticated ? "auth" : String(describing: type(of: $0))]) })

        // Queue an offline write whose server copy moves in an overlapping way:
        // the pass's flush conflicts, sync() itself still succeeds — the only
        // trace of the conflict is the onError report.
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")
        database.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        let server = try #require(database.records.first { $0.recordID.recordName == "p-1" })
        server["i_01"] = 5
        database.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        _ = try await coordinator.sync()
        #expect(errors.uuids.contains("OfflineFlushError"))

        // A periodic pass that fails between ticks reports instead of vanishing.
        database.errors = [CKError(.notAuthenticated)]
        coordinator.start(every: .milliseconds(20))
        try await poll { errors.uuids.contains("auth") }
        coordinator.stop()
    }

    private func poll(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition never held")
    }
}

// Collects the uuids periodic deltas delivered, from any thread.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: Set<String> = []

    var uuids: Set<String> {
        lock.withLock { collected }
    }

    func add(_ uuids: [String]) {
        lock.withLock { collected.formUnion(uuids) }
    }
}

// Forwards everything to the in-memory double, but parks zone-delta fetches
// behind a gate so a test can hold a sync pass open and count the passes.
private final class GatedDatabase: CloudDatabase, @unchecked Sendable {
    let backing: InMemoryDatabase
    let gate = Gate()

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        await gate.pass()
        return try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await backing.save(record)
    }

    func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await backing.modifyRecords(saving: records, deleting: recordIDs)
    }

    func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await backing.saveIfUnchanged(records)
    }

    func save(subscription: CKSubscription) async throws {
        try await backing.save(subscription: subscription)
    }

    func deleteSubscription(id: CKSubscription.ID) async throws {
        try await backing.deleteSubscription(id: id)
    }

    func subscriptions() async throws -> [CKSubscription] {
        try await backing.subscriptions()
    }

    func save(zone: CKRecordZone) async throws {
        try await backing.save(zone: zone)
    }

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await backing.fetchRecord(id: id)
    }

    func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}

// A one-way gate: calls park in `pass()` until `open()`, and a test can wait
// for the first arrival to know a pass is parked.
private actor Gate {
    private(set) var calls = 0
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        calls += 1
        arrivals.forEach { $0.resume() }
        arrivals = []
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func open() {
        isOpen = true
        parked.forEach { $0.resume() }
        parked = []
    }

    func awaitArrival() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}
