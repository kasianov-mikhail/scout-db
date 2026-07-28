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

            try await f.store.write(orderValues(), entity: entity, uuid: "zd-2")
            try await eventually {
                try await f.database.databaseChanges(since: token).changed.contains(f.zoneID)
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

    @Test("A refreshed replica answers reads the server would")
    func replicaServesUnpluggedReads() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [3, 1, 2].enumerated() {
                try await f.store.write(orderValues(product: "sku-\(index)", quantity: quantity), entity: entity, uuid: "r-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            let unplugged = UnpluggedReads(backing: f.database)
            let replica = ReplicaCache(backing: unplugged, zoneID: f.zoneID)
            try await eventually {
                try await replica.refresh(batchSize: 2)
                return replica.recordCount >= 3
            }
            unplugged.unplug()

            let offline = EntityStore(database: replica, registry: f.registry, zoneID: f.zoneID)
            let filtered = try await offline.read(entity: entity, filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
            #expect(Set(filtered.map(\.uuid)) == ["r-0", "r-2"])
            let sorted = try await offline.read(entity: entity, sort: [.init(field: "quantity", ascending: false)], fields: ["quantity"])
            #expect(sorted.map(\.uuid) == ["r-0", "r-2", "r-1"])
            #expect(sorted.first?.values["product"] == nil)
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

/// Passes reads through until `unplug()`, and fails them as offline after it —
/// the mirror is built while the network works, then answers on its own.
private final class UnpluggedReads: CloudDatabase, @unchecked Sendable {
    let backing: any CloudDatabase
    private let lock = NSLock()
    private var unplugged = false

    init(backing: any CloudDatabase) {
        self.backing = backing
    }

    func unplug() {
        lock.withLock { unplugged = true }
    }

    private func reachable() throws {
        if lock.withLock({ unplugged }) {
            throw CKError(.networkUnavailable)
        }
    }

    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try reachable()
        return try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try reachable()
        return try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
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
