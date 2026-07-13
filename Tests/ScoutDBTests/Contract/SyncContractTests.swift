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
