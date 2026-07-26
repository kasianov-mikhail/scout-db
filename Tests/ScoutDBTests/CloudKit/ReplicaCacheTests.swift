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

        backing.errors = [CKError(.networkUnavailable)]
        let sorted = try await store.read(entity: "purchase", sort: [.init(field: "quantity", ascending: false)], fields: ["quantity"])
        #expect(sorted.map(\.uuid) == ["p-0", "p-2", "p-1"])
        #expect(sorted.first?.values["product_id"] == nil)
    }

    @Test("The scan order absorbs single writes and deletes without a rebuild")
    func incrementalScanOrder() async throws {
        try await writePurchases([1, 2, 3, 4, 5])

        backing.errors = [CKError(.networkUnavailable)]
        let query = CKQuery(recordType: "Entity", predicate: NSPredicate(value: true))
        _ = try await replica.records(matching: query, inZone: zone, desiredKeys: nil, resultsLimit: 0)

        var values = makePurchase().values
        values["quantity"] = .int(9)
        try await store.write(values, entity: "purchase", uuid: "p-0a")
        try await store.write(values, entity: "purchase", uuid: "p-2")
        try await store.delete(entity: "purchase", uuid: "p-4")

        backing.errors = [CKError(.networkUnavailable)]
        let scanned = try await replica.records(matching: query, inZone: zone, desiredKeys: nil, resultsLimit: 0)
        let names = scanned.matchResults.map(\.0.recordName)
        #expect(names == names.sorted())
        #expect(names.contains("p-0a"))
        #expect(Set(names).count == names.count)
        let rewritten = try #require(scanned.matchResults.first { $0.0.recordName == "p-2" }.flatMap { try? $0.1.get() })
        #expect(rewritten["i_01"] as? Int64 == 9)
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

        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2"])

        try await writePurchases([4], through: store)
        var values = makePurchase().values
        values["quantity"] = .int(9)
        try await store.write(values, entity: "purchase", uuid: "p-9")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2", "p-9"])

        try await store.delete(entity: "purchase", uuid: "p-9")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2"])

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

        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await direct.update(entity: "purchase", uuid: "p-0") { $0.values["quantity"] = .int(9) }
        _ = try await replica.zoneChanges(zoneID: zone, since: nil, desiredKeys: nil, resultsLimit: nil)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.first?.values["quantity"] == .int(9))

        _ = try await replica.zoneChanges(zoneID: zone, since: nil, desiredKeys: ["e_uuid"], resultsLimit: nil)
        backing.errors = [CKError(.networkUnavailable)]
        let after = try await store.read(entity: "purchase")
        #expect(after.first?.values["quantity"] == .int(9))

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

        #expect(!replica.hasCompleteMirror)
        try await replica.refresh()
        #expect(replica.hasCompleteMirror)

        backing.errors = [CKError(.notAuthenticated)]
        let filtered = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
        #expect(Set(filtered.map(\.uuid)) == ["p-0", "p-2"])
        #expect(backing.errors.count == 1)
        backing.errors = []

        var values = makePurchase().values
        values["quantity"] = .int(7)
        try await store.write(values, entity: "purchase", uuid: "p-new")
        backing.errors = [CKError(.notAuthenticated)]
        let after = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .equals, value: .int(7))])
        #expect(after.map(\.uuid) == ["p-new"])
        backing.errors = []

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

    @Test("A predicate the mirror cannot express goes to the server")
    func inexpressiblePredicateDefers() async throws {
        let replica = ReplicaCache(backing: backing, zoneID: zone, readPolicy: .localFirst)
        let store = EntityStore(database: replica, registry: registry, zoneID: zone)
        try await writePurchases([3], through: store)
        try await replica.refresh()
        #expect(replica.hasCompleteMirror)

        let expressible = CKQuery(recordType: "Entity", predicate: NSPredicate(format: "entity == %@", "purchase"))
        backing.errors = [CKError(.notAuthenticated)]
        let served = try await replica.records(matching: expressible, inZone: zone, desiredKeys: nil, resultsLimit: 0)
        #expect(served.matchResults.count == 1)
        #expect(backing.errors.count == 1)

        let inexpressible = CKQuery(recordType: "Entity", predicate: NSPredicate(format: "s_00 LIKE %@", "p-*"))
        await #expect(throws: CKError.self) {
            try await replica.records(matching: inexpressible, inZone: zone, desiredKeys: nil, resultsLimit: 0)
        }
        #expect(backing.errors.isEmpty)
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

        let second = ReplicaCache(backing: backing, zoneID: zone, storeURL: url, readPolicy: .localFirst)
        #expect(second.hasCompleteMirror)
        let store = EntityStore(database: second, registry: registry, zoneID: zone)
        backing.errors = [CKError(.notAuthenticated)]
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-0"])
        #expect(backing.errors.count == 1)
    }

    @Test("Online full-fidelity query pages feed the mirror")
    func onlineReadsFeedMirror() async throws {
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

        backing.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable)]
        #expect(try await mine.read(entity: "purchase").map(\.uuid) == ["z-a"])
        #expect(try await theirs.read(entity: "purchase").map(\.uuid) == ["z-b"])

        #expect(!replica.hasCompleteMirror)
        try await replica.refresh()
        #expect(replica.hasCompleteMirror)
    }

    @Test("discoverZones registers active zones incrementally")
    func zoneDiscovery() async throws {
        let direct = EntityStore(database: backing, registry: SchemaRegistry(database: backing), zoneID: zone)
        try await direct.write(makePurchase().values, entity: "purchase", uuid: "d-1")

        let replica = ReplicaCache(backing: backing, zones: [])
        let added = try await replica.discoverZones()
        #expect(added.contains(zone))
        #expect(replica.zoneIDs.contains(zone))
        #expect(try await replica.discoverZones().isEmpty)

        try await replica.refresh()
        let store = EntityStore(database: replica, registry: SchemaRegistry(database: replica), zoneID: zone)
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

        backing.errors = [CKError(.networkUnavailable)]
        let covered = try await store.read(
            entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))], fields: ["quantity"])
        #expect(Set(covered.map(\.uuid)) == ["p-0", "p-2"])
        #expect(covered.first?.values["product_id"] == nil)

        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase")
        }

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

        backing.errors = [CKError(.notAuthenticated)]
        let covered = try await store.read(entity: "purchase", fields: ["quantity"])
        #expect(covered.first?.values["quantity"] == .int(3))
        #expect(backing.errors.count == 1)
        backing.errors = []

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

        backing.writeErrors = [CKError(.networkFailure)]
        var values = makePurchase().values
        values["quantity"] = .int(8)
        try await store.write(values, entity: "purchase", uuid: "p-2")
        #expect(cache.pendingWrites == 1)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(5))])
        #expect(offline.map(\.uuid) == ["p-2"])

        try await cache.flush()
        #expect(try await store.read(entity: "purchase").count == 2)
    }
}
