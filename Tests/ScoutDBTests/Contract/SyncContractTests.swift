//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB
import Testing

/// The zone, delta-sync, and concurrency behaviors of the `CloudDatabase` seam.
@Suite("Contract: sync")
struct SyncContractTests {
    @Test("Zones isolate records of the same entity")
    func zoneIsolation() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            let siblingZone = CKRecordZone.ID(zoneName: f.zoneID.zoneName + "_b")
            let sibling = EntityStore(database: f.database, registry: f.registry, zoneID: siblingZone)
            try await sibling.ensureZone()

            try await f.store.write(orderValues(product: "mine"), entity: entity, uuid: "z-a")
            try await sibling.write(orderValues(product: "theirs"), entity: entity, uuid: "z-b")

            try await eventually { try await f.store.read(entity: entity).map(\.uuid) == ["z-a"] }
            try await eventually { try await sibling.read(entity: entity).map(\.uuid) == ["z-b"] }

            // Best-effort: a failed assertion above leaks the sibling zone, but
            // the run-salted name keeps it inert either way.
            if let database = f.database as? CKDatabase {
                _ = try? await database.modifyRecordZones(saving: [], deleting: [siblingZone])
            }
        }
    }

    @Test("Zone deltas report writes and deletes incrementally")
    func zoneChangesDelta() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(), entity: entity, uuid: "zc-1")
            try await f.store.write(orderValues(), entity: entity, uuid: "zc-2")

            let initial = try await f.store.zoneChanges()
            #expect(Set(initial.records.map(\.uuid)) == ["zc-1", "zc-2"])
            #expect(initial.token != nil)

            // A ScoutDB delete is a tombstone rewrite, so it arrives in the
            // incremental delta as a changed record with `deleted` set — and
            // the untouched record stays out of the delta entirely.
            try await f.store.delete(entity: entity, uuid: "zc-1")
            let delta = try await f.store.zoneChanges(since: initial.token)
            #expect(delta.records.map(\.uuid) == ["zc-1"])
            #expect(delta.records.first?.deleted == true)
        }
    }

    @Test("Zone discovery reports zones with new activity incrementally")
    func zoneDiscovery() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(), entity: entity, uuid: "zd-1")

            var token: Data?
            try await eventually {
                let initial = try await f.database.databaseChanges(since: nil)
                token = initial.token
                return initial.changed.contains(f.zoneID)
            }

            // Quiet zones stay out of the incremental feed until they move again.
            try await f.store.write(orderValues(), entity: entity, uuid: "zd-2")
            try await eventually {
                try await f.database.databaseChanges(since: token).changed.contains(f.zoneID)
            }
        }
    }

    @Test("A batched zone walk pages the feed with per-batch tokens")
    func batchedZoneChanges() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for index in 0..<5 {
                try await f.store.write(orderValues(), entity: entity, uuid: "bz-\(index)")
            }

            // The walk drains the feed in several small batches; each one
            // carries a token the next incremental pass can start from.
            var uuids: [String] = []
            var batches = 0
            var last: Data?
            for try await delta in f.store.zoneChanges(batchSize: 2) {
                uuids += delta.records.map(\.uuid)
                last = delta.token ?? last
                batches += 1
            }
            #expect(Set(uuids) == ["bz-0", "bz-1", "bz-2", "bz-3", "bz-4"])
            #expect(batches >= 2)

            // The combined walk left nothing behind.
            let after = try await f.store.zoneChanges(since: last)
            #expect(after.records.isEmpty)
        }
    }

    @Test("A projected zone pass carries only the requested fields")
    func projectedZoneChanges() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(product: "sku-9", quantity: 4, note: "heavy payload"), entity: entity, uuid: "pz-1")

            let delta = try await f.store.zoneChanges(projecting: [SyncProjection(entity: entity, fields: ["quantity"])])
            let record = try #require(delta.records.first { $0.uuid == "pz-1" })
            #expect(record.values["quantity"] == .int(4))
            #expect(record.values["product"] == nil)
            #expect(record.values["note"] == nil)

            // The unprojected pass still carries everything.
            let full = try await f.store.zoneChanges()
            #expect(try #require(full.records.first { $0.uuid == "pz-1" }).values["product"] == .string("sku-9"))
        }
    }

    @Test("Subscriptions save, list, and delete by id")
    func subscriptionLifecycle() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            let id = try await f.store.subscribe(entity: entity, id: "contract-sub-\(entity)")

            try await eventually { try await f.store.subscriptions().contains { $0.subscriptionID == id } }
            try await f.store.unsubscribe(id: id)
            try await eventually { try await f.store.subscriptions().allSatisfy { $0.subscriptionID != id } }
        }
    }

    // A real network cannot be unplugged from a test, so reads fail through a
    // wrapper while the feed stays reachable — the replica must then answer
    // exactly what the server answered before the plug was pulled.
    @Test("A refreshed replica answers reads the server would")
    func replicaServesUnpluggedReads() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [3, 1, 2].enumerated() {
                try await f.store.write(orderValues(product: "sku-\(index)", quantity: quantity), entity: entity, uuid: "r-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            let replica = ReplicaCache(backing: UnpluggedReads(backing: f.database), zoneID: f.zoneID)
            try await eventually {
                try await replica.refresh(batchSize: 2)
                return replica.recordCount >= 3
            }

            // Filters, sorts, and projections all run against the mirror.
            let offline = EntityStore(database: replica, registry: f.registry, zoneID: f.zoneID)
            let filtered = try await offline.read(entity: entity, filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
            #expect(Set(filtered.map(\.uuid)) == ["r-0", "r-2"])
            let sorted = try await offline.read(entity: entity, sort: [.init(field: "quantity", ascending: false)], fields: ["quantity"])
            #expect(sorted.map(\.uuid) == ["r-0", "r-2", "r-1"])
            #expect(sorted.first?.values["product"] == nil)
        }
    }

    // Both backends compare change tags: the double stamps a fresh tag on
    // every landed save, so a stale copy conflicts exactly like on the server.
    @Test("A stale conditional save loses to the server copy")
    func staleConditionalSave() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(product: "base"), entity: entity, uuid: "cas-1")
            try await eventually { try await f.store.read(entity: entity).count == 1 }

            let id = CKRecord.ID(recordName: "cas-1", zoneID: f.zoneID)
            let fresh = try #require(try await f.database.fetchRecord(id: id))
            let stale = try #require(try await f.database.fetchRecord(id: id))

            fresh["s_00"] = "winner"
            for (_, result) in try await f.database.saveIfUnchanged([fresh]) {
                _ = try result.get()
            }

            stale["s_00"] = "loser"
            let results = try await f.database.saveIfUnchanged([stale])
            #expect(
                results.contains { _, result in
                    guard case .failure(let error) = result else { return false }
                    return error is RecordConflictError || (error as? CKError)?.code == .serverRecordChanged
                })
        }
    }
}

// Fails every query the way a dropped network would, while writes and the
// change feed stay reachable — the harness for exercising the replica's
// offline reads against a live container.
private final class UnpluggedReads: CloudDatabase, @unchecked Sendable {
    let backing: any CloudDatabase

    init(backing: any CloudDatabase) {
        self.backing = backing
    }

    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        throw CKError(.networkUnavailable)
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        throw CKError(.networkUnavailable)
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

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}
