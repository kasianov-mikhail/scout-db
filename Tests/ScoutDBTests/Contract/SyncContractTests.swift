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

            if let database = f.database as? CKDatabase {
                _ = try? await database.modifyRecordZones(saving: [], deleting: [siblingZone])
            }
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
