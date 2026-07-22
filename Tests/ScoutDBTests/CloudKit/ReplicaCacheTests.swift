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

@Suite("Replica cache")
struct ReplicaCacheTests {
    let backing = InMemoryDatabase()
    let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
    let replica: ReplicaCache
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        replica = ReplicaCache(backing: backing, zoneID: zone)
        registry = SchemaRegistry(database: replica)
        store = EntityStore(database: replica, registry: registry, zoneID: zone)
        try await registry.publish(makePurchaseDefinition())
        try await store.ensureZone()
    }

    private func writePurchases(_ quantities: [Int], through store: EntityStore? = nil) async throws {
        for (index, quantity) in quantities.enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await (store ?? self.store).write(values, entity: "purchase", uuid: "p-\(index)")
        }
    }

    @Test("A query never run before is answered from the mirror offline")
    func novelQueryOffline() async throws {
        try await writePurchases([3, 1, 2])

        backing.errors = [CKError(.networkUnavailable)]
        let filtered = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
        #expect(Set(filtered.map(\.uuid)) == ["p-0", "p-2"])

        // Sorting and projections run locally too.
        backing.errors = [CKError(.networkUnavailable)]
        let sorted = try await store.read(entity: "purchase", sort: [.init(field: "quantity", ascending: false)], fields: ["quantity"])
        #expect(sorted.map(\.uuid) == ["p-0", "p-2", "p-1"])
        #expect(sorted.first?.values["product_id"] == nil)
    }

    @Test("Offline pagination walks the mirror with offset cursors")
    func offlinePagination() async throws {
        try await writePurchases([1, 2, 3, 4, 5])

        backing.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable), CKError(.networkUnavailable)]
        let query = CKQuery(recordType: "Entity", predicate: NSPredicate(value: true))
        var collected: [String] = []
        var response = try await replica.records(matching: query, inZone: zone, desiredKeys: nil, resultsLimit: 2)
        collected += response.matchResults.map(\.0.recordName)
        while let cursor = response.queryCursor {
            response = try await replica.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: 2)
            collected += response.matchResults.map(\.0.recordName)
        }
        #expect(collected == collected.sorted())
        #expect(Set(collected).count == 5)
    }

    @Test("The scan order follows the mirror through writes and deletes")
    func scanOrderTracksMirror() async throws {
        try await writePurchases([1, 2, 3])

        // Serve a local scan first, so the order is memoized before the mirror moves.
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2"])

        // A record added after that scan must still join the next one, in order.
        try await writePurchases([4], through: store)
        var values = makePurchase().values
        values["quantity"] = .int(9)
        try await store.write(values, entity: "purchase", uuid: "p-9")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2", "p-9"])

        // And a deleted one must leave it.
        try await store.delete(entity: "purchase", uuid: "p-9")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2"])

        // Paging the refreshed mirror still walks one stable, sorted sequence.
        backing.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable), CKError(.networkUnavailable)]
        let query = CKQuery(recordType: "Entity", predicate: NSPredicate(value: true))
        var collected: [String] = []
        var response = try await replica.records(matching: query, inZone: zone, desiredKeys: nil, resultsLimit: 2)
        collected += response.matchResults.map(\.0.recordName)
        while let cursor = response.queryCursor {
            response = try await replica.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: 2)
            collected += response.matchResults.map(\.0.recordName)
        }
        #expect(collected == collected.sorted())
        #expect(Set(collected).count == collected.count)
    }

    @Test("refresh walks the feed from the replica's own token")
    func refreshBuildsMirror() async throws {
        // Records written behind the replica's back — straight into the backing.
        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await writePurchases([1, 2, 3, 4, 5], through: direct)

        #expect(try await replica.refresh(batchSize: 2) >= 5)
        #expect(try await replica.refresh(batchSize: 2) == 0)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.count == 5)
    }

    @Test("Full feed passes flowing through keep the mirror fresh; projected ones do not corrupt it")
    func passiveFeeding() async throws {
        try await writePurchases([3])

        // Another client's edit arrives with a coordinator-style full pass.
        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await direct.update(entity: "purchase", uuid: "p-0") { $0.values["quantity"] = .int(9) }
        _ = try await replica.zoneChanges(zoneID: zone, since: nil, desiredKeys: nil, resultsLimit: nil)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.first?.values["quantity"] == .int(9))

        // A projected pass misses fields — it must not trim mirrored records.
        _ = try await replica.zoneChanges(zoneID: zone, since: nil, desiredKeys: ["e_uuid"], resultsLimit: nil)
        backing.errors = [CKError(.networkUnavailable)]
        let after = try await store.read(entity: "purchase")
        #expect(after.first?.values["quantity"] == .int(9))

        // A hard delete in the feed leaves the mirror too.
        try await backing.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: "p-0", zoneID: zone)])
        _ = try await replica.zoneChanges(zoneID: zone, since: nil, desiredKeys: nil, resultsLimit: nil)
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").isEmpty)
    }

    @Test("localFirst serves zone reads from the mirror without touching the network")
    func localFirstReads() async throws {
        let replica = ReplicaCache(backing: backing, zoneID: zone, readPolicy: .localFirst)
        let store = EntityStore(database: replica, registry: registry, zoneID: zone)
        try await writePurchases([3, 1, 2], through: store)

        // Before the first completed refresh the policy stays network-first.
        #expect(!replica.hasCompleteMirror)
        try await replica.refresh()
        #expect(replica.hasCompleteMirror)

        // A poisoned backing proves the read never leaves the mirror.
        backing.errors = [CKError(.notAuthenticated)]
        let filtered = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
        #expect(Set(filtered.map(\.uuid)) == ["p-0", "p-2"])
        #expect(backing.errors.count == 1)
        backing.errors = []

        // A write through the replica is visible to the very next local read.
        var values = makePurchase().values
        values["quantity"] = .int(7)
        try await store.write(values, entity: "purchase", uuid: "p-new")
        backing.errors = [CKError(.notAuthenticated)]
        let after = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .equals, value: .int(7))])
        #expect(after.map(\.uuid) == ["p-new"])
        backing.errors = []

        // Local scans page with the mirror's own cursors, network untouched.
        backing.errors = [CKError(.notAuthenticated)]
        let query = CKQuery(recordType: "Entity", predicate: NSPredicate(value: true))
        var collected: [String] = []
        var response = try await replica.records(matching: query, inZone: zone, desiredKeys: nil, resultsLimit: 2)
        collected += response.matchResults.map(\.0.recordName)
        while let cursor = response.queryCursor {
            response = try await replica.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: 2)
            collected += response.matchResults.map(\.0.recordName)
        }
        #expect(Set(collected).count == 4)
        #expect(backing.errors.count == 1)
    }

    @Test("localFirst completeness survives a relaunch")
    func localFirstPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-replica-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try await writePurchases([3])
        let first = ReplicaCache(backing: backing, zoneID: zone, storeURL: url, readPolicy: .localFirst)
        try await first.refresh()
        #expect(first.hasCompleteMirror)
        first.persistNow()

        // The relaunched replica serves locally from the first read.
        let second = ReplicaCache(backing: backing, zoneID: zone, storeURL: url, readPolicy: .localFirst)
        #expect(second.hasCompleteMirror)
        let store = EntityStore(database: second, registry: registry, zoneID: zone)
        backing.errors = [CKError(.notAuthenticated)]
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-0"])
        #expect(backing.errors.count == 1)
    }

    @Test("Online full-fidelity query pages feed the mirror")
    func onlineReadsFeedMirror() async throws {
        // Records written behind the replica's back become visible offline
        // after one plain online read through it.
        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await writePurchases([4, 5], through: direct)
        _ = try await store.read(entity: "purchase")

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .equals, value: .int(5))])
        #expect(offline.map(\.uuid) == ["p-1"])
    }

    @Test("A tombstone written through the replica hides the record offline")
    func tombstonesOffline() async throws {
        try await writePurchases([3, 1])
        try await store.delete(entity: "purchase", uuid: "p-0")

        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-1"])
    }

    @Test("The mirror persists across a relaunch")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-replica-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ReplicaCache(backing: backing, zoneID: zone, storeURL: url)
        let firstStore = EntityStore(database: first, registry: SchemaRegistry(database: first), zoneID: zone)
        var values = makePurchase().values
        values["quantity"] = .int(7)
        try await firstStore.write(values, entity: "purchase", uuid: "p-persist")
        try await first.refresh()
        first.persistNow()

        // The relaunched replica serves offline reads and resumes the feed
        // from its persisted position.
        let second = ReplicaCache(backing: backing, zoneID: zone, storeURL: url)
        #expect(second.recordCount == first.recordCount)
        #expect(try await second.refresh() == 0)
        let secondStore = EntityStore(database: second, registry: registry, zoneID: zone)
        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await secondStore.read(entity: "purchase", filters: [.init(field: "quantity", op: .equals, value: .int(7))])
        #expect(offline.map(\.uuid) == ["p-persist"])
    }

    @Test("A deferred mirror write reaches the store without being forced")
    func deferredPersistLandsOnItsOwn() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-replica-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let replica = ReplicaCache(backing: backing, zoneID: zone, storeURL: url)
        let store = EntityStore(database: replica, registry: SchemaRegistry(database: replica), zoneID: zone)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-deferred")

        // No persistNow() here: the scheduled write has to settle on its own,
        // or a replica that is never forced would never reach disk at all.
        var restored = 0
        for _ in 0..<40 where restored == 0 {
            try await Task.sleep(for: .milliseconds(50))
            restored = ReplicaCache(backing: backing, zoneID: zone, storeURL: url).recordCount
        }
        #expect(restored > 0)
    }

    @Test("One replica mirrors several zones with per-zone completeness")
    func multipleZones() async throws {
        let second = CKRecordZone.ID(zoneName: "scout_b", ownerName: CKCurrentUserDefaultName)
        let replica = ReplicaCache(backing: backing, zones: [zone, second])
        let registry = SchemaRegistry(database: replica)
        let mine = EntityStore(database: replica, registry: registry, zoneID: zone)
        let theirs = EntityStore(database: replica, registry: registry, zoneID: second)
        try await theirs.ensureZone()

        try await mine.write(makePurchase().values, entity: "purchase", uuid: "z-a")
        try await theirs.write(makePurchase().values, entity: "purchase", uuid: "z-b")

        // Offline reads stay zone-scoped: each store sees only its zone.
        backing.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable)]
        #expect(try await mine.read(entity: "purchase").map(\.uuid) == ["z-a"])
        #expect(try await theirs.read(entity: "purchase").map(\.uuid) == ["z-b"])

        // Completeness is per zone: refreshing both flips the whole mirror.
        #expect(!replica.hasCompleteMirror)
        try await replica.refresh()
        #expect(replica.hasCompleteMirror)
    }

    @Test("discoverZones registers active zones incrementally")
    func zoneDiscovery() async throws {
        // Records land behind the replica's back; the database feed leads to them.
        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await direct.write(makePurchase().values, entity: "purchase", uuid: "d-1")

        let replica = ReplicaCache(backing: backing, zones: [])
        let added = try await replica.discoverZones()
        #expect(added.contains(zone))
        #expect(replica.zoneIDs.contains(zone))
        // Discovery is incremental — a quiet feed adds nothing new.
        #expect(try await replica.discoverZones().isEmpty)

        try await replica.refresh()
        let store = EntityStore(database: replica, registry: SchemaRegistry(database: replica), zoneID: zone)
        // One online read warms the schema cache; the offline one hits the mirror.
        _ = try await store.read(entity: "purchase")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["d-1"])
    }

    @Test("A partial replica serves only the reads its fields cover")
    func partialReplica() async throws {
        let keys = try await store.replicaFields(projecting: [SyncProjection(entity: "purchase", fields: ["quantity"])])
        let partial = ReplicaCache(backing: backing, zoneID: zone, fields: keys)
        let store = EntityStore(database: partial, registry: SchemaRegistry(database: partial), zoneID: zone)
        try await writePurchases([3, 1, 2], through: store)
        try await partial.refresh()

        // A projected read the whitelist covers is served offline, trimmed.
        backing.errors = [CKError(.networkUnavailable)]
        let covered = try await store.read(
            entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))], fields: ["quantity"])
        #expect(Set(covered.map(\.uuid)) == ["p-0", "p-2"])
        #expect(covered.first?.values["product_id"] == nil)

        // A full read is refused — the mirror cannot fabricate missing fields.
        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase")
        }

        // So is one that filters on an unmirrored field.
        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(
                entity: "purchase", filters: [.init(field: "product_id", op: .equals, value: .string("sku-1"))], fields: ["quantity"])
        }
    }

    @Test("A partial localFirst replica sends uncovered reads to the network")
    func partialLocalFirst() async throws {
        let keys = try await store.replicaFields(projecting: [SyncProjection(entity: "purchase", fields: ["quantity"])])
        let partial = ReplicaCache(backing: backing, zoneID: zone, readPolicy: .localFirst, fields: keys)
        let store = EntityStore(database: partial, registry: SchemaRegistry(database: partial), zoneID: zone)
        try await writePurchases([3], through: store)
        try await partial.refresh()

        // The covered read never touches the poisoned backing.
        backing.errors = [CKError(.notAuthenticated)]
        let covered = try await store.read(entity: "purchase", fields: ["quantity"])
        #expect(covered.first?.values["quantity"] == .int(3))
        #expect(backing.errors.count == 1)
        backing.errors = []

        // The uncovered read goes to the network and comes back whole.
        let full = try await store.read(entity: "purchase")
        #expect(full.first?.values["product_id"] != nil)
    }

    @Test("Composed outside an offline cache, queued writes reach novel offline queries")
    func composesWithOfflineCache() async throws {
        let cache = OfflineCache(backing: backing)
        let replica = ReplicaCache(backing: cache, zoneID: zone)
        let registry = SchemaRegistry(database: replica)
        let store = EntityStore(database: replica, registry: registry, zoneID: zone)
        try await registry.publish(makePurchaseDefinition())
        try await store.ensureZone()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        // Offline: the queue takes the write, the mirror still learns it.
        backing.writeErrors = [CKError(.networkFailure)]
        var values = makePurchase().values
        values["quantity"] = .int(8)
        try await store.write(values, entity: "purchase", uuid: "p-2")
        #expect(cache.pendingWrites == 1)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(5))])
        #expect(offline.map(\.uuid) == ["p-2"])

        // Back online the flush lands the queued write for real.
        try await cache.flush()
        #expect(try await store.read(entity: "purchase").count == 2)
    }
}
