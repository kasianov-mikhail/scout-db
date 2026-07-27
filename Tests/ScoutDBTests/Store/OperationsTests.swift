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

@Suite("Operations")
struct OperationsTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("CAS update applies the transform to the stored record")
    func update() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(7)
        }
        let records = try await store.read(entity: "purchase")
        #expect(records.first?.values["quantity"] == .int(7))
    }

    @Test("A fetch by uuid reads a record the query index has not caught up with")
    func fetchByUUIDSkipsTheIndex() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        database.unindexed = [CKRecord.ID(recordName: "p-1", zoneID: .default)]

        #expect(try await store.read(entity: "purchase").isEmpty)
        #expect(try await store.fetch(uuid: "p-1")?.uuid == "p-1")
        #expect(try await store.fetch(uuid: "p-9") == nil)
    }

    @Test("CAS update retries after a conflict")
    func updateConflict() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server)]
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        let records = try await store.read(entity: "purchase")
        #expect(records.first?.values["quantity"] == .int(9))
    }

    @Test("An update that moves a unique key onto a taken value throws")
    func updateUniqueKeyCollision() async throws {
        try await registry.publish(makeSeatDefinition())
        try await store.write(["row": .string("a"), "number": .int(1)], entity: "seat", uuid: "seat-1")
        try await store.write(["row": .string("a"), "number": .int(2)], entity: "seat", uuid: "seat-2")
        await #expect(throws: SchemaError.duplicateKey(fields: ["row", "number"])) {
            try await store.update(entity: "seat", uuid: "seat-2") { record in
                record.values["number"] = .int(1)
            }
        }
    }

    @Test("An update that leaves unique keys untouched skips their validation")
    func updateUntouchedUniqueKeys() async throws {
        try await registry.publish(makeSeatDefinition())
        try await store.write(["row": .string("a"), "number": .int(1)], entity: "seat", uuid: "seat-1")
        try await store.write(["row": .string("a"), "number": .int(2)], entity: "seat", uuid: "seat-2")
        let raced = try #require(database.records.first { $0["uuid"] as? String == "seat-2" })
        raced["i_00"] = Int64(1)
        try await store.update(entity: "seat", uuid: "seat-2") { record in
            record.values["label"] = .string("window")
        }
        let records = try await store.read(entity: "seat", filters: [.init(field: "label", op: .equals, value: .string("window"))])
        #expect(records.map(\.uuid) == ["seat-2"])
    }

    @Test("A transform that clears fields clears their stored slot and payload values")
    func updateClears() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = nil
            record.values["comment"] = nil
        }
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == nil)
        #expect(record.values["comment"] == nil)
        #expect(record.values["product_id"] == .string("sku-42"))
    }

    @Test("Bulk update retries records that lost their save race")
    func updateAllConflict() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server)]

        let updated = try await store.updateAll(entity: "purchase") { record in
            record.values["quantity"] = .int(9)
        }

        #expect(updated == 2)
        let records = try await store.read(entity: "purchase")
        #expect(records.allSatisfy { $0.values["quantity"] == .int(9) })
    }

    @Test("Bulk update surfaces a conflict that outlives the retries, keeping the saves that landed")
    func updateAllConflictExhausted() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = (0..<3).map { _ in RecordConflictError(serverRecord: server.copy() as! CKRecord) }

        await #expect(throws: RecordConflictError.self) {
            try await store.updateAll(entity: "purchase") { record in
                record.values["quantity"] = .int(9)
            }
        }

        let records = try await store.read(entity: "purchase")
        #expect(records.first { $0.uuid == "p-2" }?.values["quantity"] == .int(9))
        #expect(records.first { $0.uuid == "p-1" }?.values["quantity"] != .int(9))
    }

    @Test("Non-overlapping edits merge on conflict without re-running the transform")
    func conflictFieldMerge() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let winner = try #require(try await database.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        winner["s_00"] = "sku-99"
        database.writeErrors = [RecordConflictError(serverRecord: winner)]
        var runs = 0
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            runs += 1
            record.values["quantity"] = .int(9)
        }
        #expect(runs == 1)
        let merged = try #require(try await store.read(entity: "purchase").first)
        #expect(merged.values["quantity"] == .int(9))
        #expect(merged.values["product_id"] == .string("sku-99"))

        let overlap = try #require(try await database.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        overlap["i_01"] = Int64(100)
        database.writeErrors = [RecordConflictError(serverRecord: overlap)]
        var reruns = 0
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            reruns += 1
            guard case .int(let quantity)? = record.values["quantity"] else { return }
            record.values["quantity"] = .int(quantity + 1)
        }
        #expect(reruns == 2)
        #expect(try await store.read(entity: "purchase").first?.values["quantity"] == .int(101))
    }

    @Test("A merged retry re-claims only the keys the merge moved")
    func mergedRetryKeepsItsClaims() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "badge", version: 1,
                fields: [
                    FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_01")),
                ],
                enforcedKeys: [["code"]]))
        let counting = CountingFetches(backing: database)
        let racing = EntityStore(database: counting, registry: registry)
        try await racing.write(["code": .string("gold"), "label": .string("first")], entity: "badge", uuid: "b-1")

        counting.reset()
        try await racing.update(entity: "badge", uuid: "b-1") { record in
            record.values["code"] = .string("silver")
        }
        let uncontested = counting.fetches

        counting.reset()
        try await racing.update(entity: "badge", uuid: "b-1") { record in
            record.values["code"] = .string("bronze")
            let winner = database.records.first { $0.recordID.recordName == "b-1" }
            winner?["s_01"] = "second"
            winner?.overrideChangeTag(UUID().uuidString)
        }

        #expect(counting.fetches == uncontested)
        let merged = try #require(try await racing.read(entity: "badge").first)
        #expect(merged.values["code"] == .string("bronze"))
        #expect(merged.values["label"] == .string("second"))
        #expect(database.records.filter { $0.recordType == "UniqueClaim" }.map { $0["owner"] as? String } == ["b-1"])
    }

    @Test("The independent tails of an update run in one round")
    func updateTailsRunConcurrently() async throws {
        try await registry.publish(EntityStore.revisionDefinition)
        try await registry.publish(
            EntityDefinition(
                entity: "badge", version: 1,
                fields: [
                    FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                enforcedKeys: [["code"]],
                views: [AggregateView(name: "total", bucket: .lifetime, sum: "amount")],
                audited: true))
        let counting = CountingFetches(backing: database)
        let audited = EntityStore(database: counting, registry: registry)
        try await audited.write(["code": .string("gold"), "amount": .double(1)], entity: "badge", uuid: "b-1")

        counting.reset()
        try await audited.update(entity: "badge", uuid: "b-1") { record in
            record.values["code"] = .string("silver")
            record.values["amount"] = .double(2)
        }

        #expect(counting.peakInFlight == 3)
        #expect(try await audited.history(entity: "badge", uuid: "b-1").map { $0.values["code"] } == [.string("gold")])
        #expect(database.records.first { $0.recordType == "Aggregate" }?["f_00"] as? Double == 2)
        #expect(database.records.filter { $0.recordType == "UniqueClaim" }.count == 1)
    }

    @Test("CAS update of a missing record fails")
    func updateMissing() async throws {
        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.update(entity: "purchase", uuid: "ghost") { _ in }
        }
    }

    @Test("Keyset pagination walks records in date order")
    func pagination() async throws {
        for (index, seconds) in [3_000, 1_000, 2_000].enumerated() {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let first = try await store.read(entity: "purchase", limit: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let cursor = try #require(first.cursor)

        let second = try await store.read(entity: "purchase", limit: 2, after: cursor)
        #expect(second.records.map(\.uuid) == ["p-0"])
        #expect(second.cursor == nil)
    }

    @Test("Keyset pagination orders by an arbitrary field in both directions")
    func fieldPagination() async throws {
        for (index, quantity) in [3, 1, 2, 2].enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let first = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let second = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 2, after: try #require(first.cursor))
        #expect(second.records.map(\.uuid) == ["p-3", "p-0"])

        let top = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3)
        #expect(top.records.map(\.uuid) == ["p-0", "p-2", "p-3"])
        let rest = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3, after: try #require(top.cursor))
        #expect(rest.records.map(\.uuid) == ["p-1"])
        #expect(rest.cursor == nil)

        await #expect(throws: SchemaError.invalidValue("comment")) {
            _ = try await store.read(entity: "purchase", orderedBy: "comment", limit: 1)
        }
    }

    @Test("Sorting by a payload field ranks client-side")
    func payloadSort() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "player",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "score", type: .int, storage: .payload),
                ]))
        try await store.write(["name": .string("Ada"), "score": .int(10)], entity: "player", uuid: "u-1")
        try await store.write(["name": .string("Bo"), "score": .int(5)], entity: "player", uuid: "u-2")
        try await store.write(["name": .string("Cy")], entity: "player", uuid: "u-3")

        let ranked = try await store.read(entity: "player", sort: [.init(field: "score")])
        #expect(ranked.map(\.uuid) == ["u-3", "u-2", "u-1"])

        let top = try await store.read(entity: "player", sort: [.init(field: "score", ascending: false)], limit: 2)
        #expect(top.map(\.uuid) == ["u-1", "u-2"])
        #expect(try await store.query("player").sort("score", .descending).first()?.uuid == "u-1")

        await #expect(throws: SchemaError.unknownField("ghost")) {
            _ = try await store.read(entity: "player", sort: [.init(field: "ghost")])
        }
    }

    @Test("Filters on payload fields fall back to client-side matching")
    func payloadFilters() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "score", type: .int, storage: .payload),
                    FieldDefinition(name: "tags", type: .stringList, storage: .payload),
                    FieldDefinition(name: "spot", type: .location, storage: .payload),
                ]))
        try await store.write(["name": .string("Ada"), "score": .int(10), "tags": .strings(["swift", "db"])], entity: "profile", uuid: "u-1")
        try await store.write(["name": .string("Bo"), "score": .int(5), "tags": .strings(["db"])], entity: "profile", uuid: "u-2")
        try await store.write(["name": .string("Cy")], entity: "profile", uuid: "u-3")

        func uuids(_ filters: [EntityStore.Filter]) async throws -> [String] {
            try await store.read(entity: "profile", filters: filters).map(\.uuid).sorted()
        }

        #expect(try await uuids([.init(field: "score", op: .equals, value: .int(10))]) == ["u-1"])
        #expect(try await uuids([.init(field: "score", op: .greaterThan, value: .int(4))]) == ["u-1", "u-2"])
        #expect(try await uuids([.init(field: "score", op: .lessThanOrEquals, value: .int(5))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .in, value: .ints([5, 7]))]) == ["u-2"])
        #expect(try await uuids([.init(field: "tags", op: .contains, value: .string("swift"))]) == ["u-1"])
        #expect(try await uuids([.init(field: "score", op: .notEquals, value: .int(10))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .notIn, value: .ints([10]))]) == ["u-2"])

        await #expect(throws: SchemaError.invalidValue("spot")) {
            _ = try await store.read(entity: "profile", filters: [.init(field: "spot", op: .near, value: .location(latitude: 0, longitude: 0), radius: 10)])
        }
    }

    @Test("Subscriptions register a server predicate and can be removed")
    func changeSubscriptions() async throws {
        let id = try await store.subscribe(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
        #expect(id == "scout-purchase")

        let stored = try #require(database.storedSubscriptions.first as? CKQuerySubscription)
        #expect(stored.predicate.predicateFormat.contains("entity == \"purchase\""))
        #expect(stored.predicate.predicateFormat.contains("i_01"))
        #expect(stored.notificationInfo?.shouldSendContentAvailable == true)
        #expect(try await store.subscriptions().count == 1)

        await #expect(throws: SchemaError.invalidValue("product_id")) {
            try await store.subscribe(entity: "purchase", filters: [.init(field: "product_id", op: .like, value: .string("sku*"))])
        }

        try await store.unsubscribe(id: id)
        #expect(database.storedSubscriptions.isEmpty)
    }

    @Test("A zoned store keeps entity records and tombstones in its custom zone")
    func customZone() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        try await zoned.ensureZone()
        #expect(database.zones == [zone])

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let stored = try #require(database.records.first { $0.recordType == "Entity" })
        #expect(stored.recordID.zoneID == zone)
        #expect(try await zoned.read(entity: "purchase").map(\.uuid) == ["p-1"])

        try await zoned.delete(entity: "purchase", uuid: "p-1")
        let tombstone = try #require(database.records.first { $0.recordType == "Entity" })
        #expect(tombstone.recordID.zoneID == zone)
        #expect(try await zoned.read(entity: "purchase").isEmpty)

        let descriptor = try #require(database.records.first { $0.recordType == "SchemaDescriptor" })
        #expect(descriptor.recordID.zoneID != zone)
    }

    @Test("Drop tombstones the records and retires the schema; a republish revives the entity")
    func dropEntity() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        let dropped = try await store.drop(entity: "purchase")
        #expect(dropped == 2)
        await #expect(throws: SchemaError.unknownEntity("purchase")) {
            _ = try await store.read(entity: "purchase")
        }

        let fresh = SchemaRegistry(database: database)
        try await fresh.preload()
        #expect(await fresh.definitions().isEmpty)

        try await registry.publish(makePurchaseDefinition())
        #expect(try await store.read(entity: "purchase").isEmpty)

        await #expect(throws: SchemaError.unknownEntity("ghost")) {
            try await registry.retire(entity: "ghost")
        }
    }

    @Test("Zone sharing creates one zone-wide share, finds it again, and revokes it")
    func zoneSharing() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()

        #expect(try await zoned.zoneShare() == nil)
        let share = try await zoned.shareZone(title: "Purchases")
        #expect(share.recordID.zoneID == zone)
        #expect(share.recordID.recordName == CKRecordNameZoneWideShare)

        let again = try await zoned.shareZone()
        #expect(again.recordID == share.recordID)
        #expect(database.records.filter { $0 is CKShare }.count == 1)

        try await zoned.stopSharing()
        #expect(try await zoned.zoneShare() == nil)

        await #expect(throws: SchemaError.self) {
            try await store.shareZone()
        }
    }

    @Test("A batch write unwraps a partial failure to the records that caused it")
    func partialFailureUnwrapped() async throws {
        let culprit = CKRecord.ID(recordName: "p-1")
        let innocent = CKRecord.ID(recordName: "p-2")
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [culprit: CKError(.quotaExceeded), innocent: CKError(.batchRequestFailed)]])
        database.writeErrors = [partial]

        do {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
            Issue.record("Expected a PartialWriteError")
        } catch let error as PartialWriteError {
            #expect(error.reasons.count == 1)
            #expect((error.reasons[culprit] as? CKError)?.code == .quotaExceeded)
        }

        database.writeErrors = [CKError(.partialFailure)]
        do {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
            Issue.record("Expected a CKError")
        } catch let error as CKError {
            #expect(error.code == .partialFailure)
        }
    }

    @Test("A single record shares, reports its share, and stops")
    func recordSharing() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout-share", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        let share = try await zoned.shareRecord(entity: "purchase", uuid: "p-1", title: "Trip")
        #expect(share[CKShare.SystemFieldKey.title] as? String == "Trip")
        #expect(share.recordID.zoneID == zone)

        let again = try await zoned.shareRecord(entity: "purchase", uuid: "p-1")
        #expect(again.recordID == share.recordID)
        #expect(database.records.filter { $0 is CKShare }.count == 1)

        #expect(try await zoned.recordShare(entity: "purchase", uuid: "p-2") == nil)
        await #expect(throws: SchemaError.notFound("p-1")) {
            _ = try await zoned.shareRecord(entity: "order", uuid: "p-1")
        }

        try await zoned.stopSharing(entity: "purchase", uuid: "p-1")
        #expect(try await zoned.recordShare(entity: "purchase", uuid: "p-1") == nil)
        #expect(try await zoned.read(entity: "purchase").count == 2)

        await #expect(throws: SchemaError.self) {
            _ = try await store.shareRecord(entity: "purchase", uuid: "p-1")
        }
    }

    @Test("Zone delta sync walks the change feed across entities by token")
    func zoneDeltaSync() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let first = try await zoned.zoneChanges()
        #expect(first.records.map(\.uuid) == ["p-1"])
        #expect(first.deleted.isEmpty)

        let idle = try await zoned.zoneChanges(since: first.token)
        #expect(idle.records.isEmpty)

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        try await zoned.delete(entity: "purchase", uuid: "p-1")
        let second = try await zoned.zoneChanges(since: first.token)
        #expect(Set(second.records.map(\.uuid)) == ["p-1", "p-2"])
        #expect(second.records.first { $0.uuid == "p-1" }?.deleted == true)

        await #expect(throws: SchemaError.self) {
            _ = try await store.zoneChanges()
        }
    }

    @Test("Batched zone sync walks the feed with per-batch tokens")
    func batchedZoneSync() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout-batched", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        for index in 0..<5 {
            try await zoned.write(makePurchase().values, entity: "purchase", uuid: "b-\(index)")
        }

        var batches: [ZoneDelta] = []
        for try await delta in zoned.zoneChanges(batchSize: 2) {
            batches.append(delta)
        }
        #expect(batches.map(\.records.count) == [2, 2, 1])
        #expect(batches.flatMap { $0.records.map(\.uuid) }.sorted() == ["b-0", "b-1", "b-2", "b-3", "b-4"])

        var resumed: [String] = []
        for try await delta in zoned.zoneChanges(since: batches[0].token, batchSize: 2) {
            resumed += delta.records.map(\.uuid)
        }
        #expect(resumed.sorted() == ["b-2", "b-3", "b-4"])

        var idle = 0
        for try await _ in zoned.zoneChanges(since: batches.last?.token, batchSize: 2) {
            idle += 1
        }
        #expect(idle == 0)
    }

    @Test("Push payloads map to change events and back to records")
    func pushEvents() async throws {
        #expect(ChangeEvent(reason: .recordCreated, recordName: "p-1", subscriptionID: "scout-purchase")?.kind == .created)
        #expect(ChangeEvent(reason: .recordUpdated, recordName: "p-1", subscriptionID: nil)?.kind == .updated)
        #expect(ChangeEvent(reason: .recordDeleted, recordName: "p-1", subscriptionID: nil)?.kind == .deleted)
        #expect(ChangeEvent(reason: .recordCreated, recordName: nil, subscriptionID: nil) == nil)
        #expect(ChangeEvent(userInfo: ["aps": ["alert": "hi"]]) == nil)

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let created = try #require(ChangeEvent(reason: .recordCreated, recordName: "p-1", subscriptionID: "scout-purchase"))
        #expect(try await store.record(for: created)?.values["product_id"] == .string("sku-42"))

        try await store.delete(entity: "purchase", uuid: "p-1")
        let updated = try #require(ChangeEvent(reason: .recordUpdated, recordName: "p-1", subscriptionID: nil))
        #expect(try await store.record(for: updated) == nil)
        let deleted = try #require(ChangeEvent(reason: .recordDeleted, recordName: "p-1", subscriptionID: nil))
        #expect(try await store.record(for: deleted) == nil)
    }

    @Test("A projected subscription carries its fields, and the pushed fields decode without a fetch")
    func projectedPush() async throws {
        try await store.subscribe(entity: "purchase", projecting: ["product_id", "quantity"])
        let stored = try #require(database.storedSubscriptions.first as? CKQuerySubscription)
        let keys = try #require(stored.notificationInfo?.desiredKeys)
        #expect(Set(keys).isSuperset(of: ["entity", "schema_version", "uuid", "deleted", "s_00", "i_01"]))

        database.errors = [CKError(.networkUnavailable)]
        let pushed = try await store.record(
            uuid: "p-1",
            pushedFields: [
                "entity": "purchase" as NSString, "schema_version": 2 as NSNumber, "uuid": "p-1" as NSString, "deleted": 0 as NSNumber,
                "s_00": "sku-42" as NSString, "i_01": 7 as NSNumber,
            ])
        #expect(pushed?.values["product_id"] == .string("sku-42"))
        #expect(pushed?.values["quantity"] == .int(7))
        #expect(pushed?.values["comment"] == nil)
        database.errors = []

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        #expect(try await store.record(uuid: "p-2", pushedFields: [:])?.values["product_id"] == .string("sku-42"))

        let tombstone: [String: any CKRecordValue] = [
            "entity": "purchase" as NSString, "schema_version": 2 as NSNumber, "uuid": "p-1" as NSString, "deleted": 1 as NSNumber,
        ]
        #expect(try await store.record(uuid: "p-1", pushedFields: tombstone) == nil)
    }

    @Test("The sync coordinator advances its token, persists it, and flushes the offline queue")
    func syncCoordinator() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let tokenURL = FileManager.default.temporaryDirectory.appendingPathComponent("scout-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tokenURL) }

        let cache = OfflineCache(backing: database)
        let zoned = EntityStore(database: cache, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        let coordinator = SyncCoordinator(store: zoned, cache: cache, tokenURL: tokenURL)

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(try await coordinator.sync().records.map(\.uuid) == ["p-1"])
        #expect(try await coordinator.sync().records.isEmpty)

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let pushed = try await coordinator.handlePush(["ck": ["nid": "n", "qry": ["sid": "scout-purchase", "fo": 1]]])
        #expect(pushed?.records.map(\.uuid) == ["p-2"])
        #expect(try await coordinator.handlePush(["aps": ["alert": "hi"]]) == nil)

        let relaunched = SyncCoordinator(store: zoned, cache: cache, tokenURL: tokenURL)
        #expect(try await relaunched.sync().records.isEmpty)
        relaunched.reset()
        #expect(try await relaunched.sync().records.count == 2)

        database.writeErrors = [CKError(.networkFailure)]
        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-3")
        #expect(cache.pendingWrites == 1)
        let delta = try await coordinator.sync()
        #expect(cache.pendingWrites == 0)
        #expect(delta.records.map(\.uuid).contains("p-3"))
    }

    @Test("Share participants and the public permission are managed through the store")
    func shareParticipants() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()

        #expect(try await zoned.shareParticipants().isEmpty)
        await #expect(throws: SchemaError.notFound(CKRecordNameZoneWideShare)) {
            try await zoned.setSharePublicPermission(.readOnly)
        }

        try await zoned.shareZone(title: "Purchases")
        let participants = try await zoned.shareParticipants()
        #expect(participants.count == 1)
        #expect(participants.first?.role == .owner)

        try await zoned.setSharePublicPermission(.readOnly)
        #expect(try await zoned.zoneShare()?.publicPermission == .readOnly)

        await #expect(throws: SchemaError.invalidValue("owner")) {
            try await zoned.removeShareParticipant(try #require(participants.first))
        }
        #expect(try await zoned.shareParticipants().count == 1)
    }

    @Test("A zoned store's queries stay inside its zone")
    func zoneScopedQueries() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-default")
        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-zoned")

        #expect(try await zoned.read(entity: "purchase").map(\.uuid) == ["p-zoned"])
        #expect(Set(try await store.read(entity: "purchase").map(\.uuid)) == ["p-default", "p-zoned"])

        #expect(try await zoned.fetch(uuid: "p-default") == nil)
        #expect(try await zoned.fetch(uuid: "p-zoned")?.uuid == "p-zoned")
        #expect(try await zoned.read(entity: "purchase", limit: 5).records.map(\.uuid) == ["p-zoned"])
    }

    @Test("A database subscription registers one silent-push umbrella")
    func databaseSubscription() async throws {
        let id = try await store.subscribeToDatabase()
        #expect(id == "scout-database")

        let stored = try #require(database.storedSubscriptions.first as? CKDatabaseSubscription)
        #expect(stored.subscriptionID == "scout-database")
        #expect(stored.notificationInfo?.shouldSendContentAvailable == true)

        _ = try await store.subscribeToDatabase()
        #expect(database.storedSubscriptions.count == 1)
        try await store.unsubscribe(id: id)
        #expect(database.storedSubscriptions.isEmpty)
    }

    @Test("A distance sort ranks nearest-first, missing locations last")
    func distanceSort() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "place",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "spot", type: .location, storage: .slot(.location, "g_00")),
                ]))
        try await store.write(["name": .string("near"), "spot": .location(latitude: 0.01, longitude: 0.01)], entity: "place", uuid: "l-near")
        try await store.write(["name": .string("far"), "spot": .location(latitude: 10, longitude: 10)], entity: "place", uuid: "l-far")
        try await store.write(["name": .string("nowhere")], entity: "place", uuid: "l-none")

        let ranked = try await store.read(entity: "place", sort: [.distance(from: "spot", latitude: 0, longitude: 0)])
        #expect(ranked.map(\.uuid) == ["l-near", "l-far", "l-none"])

        let closest = try await store.query("place").nearest("spot", latitude: 9, longitude: 9).first()
        #expect(closest?.uuid == "l-far")

        await #expect(throws: SchemaError.invalidValue("name")) {
            _ = try await store.read(entity: "place", sort: [.distance(from: "name", latitude: 0, longitude: 0)])
        }
    }

    @Test("Increment adds atomically, counts from zero, and survives a race")
    func increment() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        #expect(try await store.increment(entity: "purchase", uuid: "p-1", field: "quantity") == 4)
        #expect(try await store.increment(entity: "purchase", uuid: "p-1", field: "quantity", by: -2) == 2)
        #expect(try await store.increment(entity: "purchase", uuid: "p-1", field: "total", by: 1) == 30.97)

        var sparse = makePurchase().values
        sparse["quantity"] = nil
        try await store.write(sparse, entity: "purchase", uuid: "p-2")
        #expect(try await store.increment(entity: "purchase", uuid: "p-2", field: "quantity", by: 5) == 5)

        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]
        #expect(try await store.increment(entity: "purchase", uuid: "p-1", field: "quantity") == 3)

        await #expect(throws: SchemaError.invalidValue("quantity")) {
            try await store.increment(entity: "purchase", uuid: "p-1", field: "quantity", by: 0.5)
        }
        await #expect(throws: SchemaError.invalidValue("product_id")) {
            try await store.increment(entity: "purchase", uuid: "p-1", field: "product_id")
        }
        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.increment(entity: "purchase", uuid: "ghost", field: "quantity")
        }
    }

    @Test("Mutations treat a tombstoned record as absent, but restore still lifts it")
    func mutationsSkipTombstones() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "t-1")
        try await store.delete(entity: "purchase", uuid: "t-1")

        await #expect(throws: SchemaError.notFound("t-1")) {
            try await store.increment(entity: "purchase", uuid: "t-1", field: "quantity")
        }
        await #expect(throws: SchemaError.notFound("t-1")) {
            _ = try await store.lease(entity: "purchase", uuid: "t-1", owner: "me", for: 60)
        }
        await #expect(throws: SchemaError.notFound("t-1")) {
            _ = try await store.leaseHolder(entity: "purchase", uuid: "t-1")
        }

        _ = try await store.restore(entity: "purchase", uuid: "t-1")
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["t-1"])
    }

    @Test("Restore lifts a tombstone with its values, compact purges old tombstones")
    func restoreAndCompact() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.delete(entity: "purchase", uuid: "p-1")
        #expect(try await store.read(entity: "purchase").isEmpty)

        let restored = try await store.restore(entity: "purchase", uuid: "p-1")
        #expect(restored.values["product_id"] == .string("sku-42"))
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-1"])

        #expect(try await store.restore(entity: "purchase", uuid: "p-1").deleted == false)

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        try await store.delete(entity: "purchase", uuid: "p-1")
        #expect(try await store.compact(entity: "purchase", olderThan: Date(timeIntervalSince1970: 0)) == 0)
        #expect(try await store.compact(entity: "purchase", olderThan: Date().addingTimeInterval(60)) == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
        await #expect(throws: SchemaError.notFound("p-1")) {
            try await store.restore(entity: "purchase", uuid: "p-1")
        }
    }

    @Test("An audited entity appends a revision on every update and delete")
    func revisionLog() async throws {
        try await registry.publish(EntityStore.revisionDefinition)
        var audited = makePurchaseDefinition()
        audited.audited = true
        try await registry.publish(audited)

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        try await store.updateAll(entity: "purchase") { record in
            record.values["quantity"] = .int(11)
        }
        try await store.delete(entity: "purchase", uuid: "p-1")

        let history = try await store.history(entity: "purchase", uuid: "p-1")
        #expect(history.map { $0.values["quantity"] } == [.int(3), .int(9), .int(11)])
        #expect(history.allSatisfy { $0.uuid == "p-1" })

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        var plain = makePurchaseDefinition()
        plain.audited = nil
        try await registry.publish(plain)
        try await store.delete(entity: "purchase", uuid: "p-2")
        #expect(try await store.history(entity: "purchase", uuid: "p-2").isEmpty)
    }

    @Test("Compaction trims the revision log to a window, by entity or across all")
    func compactRevisions() async throws {
        try await registry.publish(EntityStore.revisionDefinition)
        var audited = makePurchaseDefinition()
        audited.audited = true
        try await registry.publish(audited)

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        let horizon = Date()
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(11)
        }

        #expect(try await store.compactRevisions(olderThan: horizon, of: "invoice") == 0)
        #expect(try await store.compactRevisions(olderThan: horizon) == 1)
        #expect(try await store.history(entity: "purchase", uuid: "p-1").map { $0.values["quantity"] } == [.int(9)])
        #expect(try await store.compactRevisions(olderThan: Date().addingTimeInterval(60)) == 1)
        #expect(try await store.history(entity: "purchase", uuid: "p-1").isEmpty)
    }

    @Test("Revisions sharing a millisecond order deterministically by revision id")
    func revisionTieBreak() async throws {
        try await registry.publish(EntityStore.revisionDefinition)

        let date = Date(timeIntervalSince1970: 1_000)
        func revision(uuid: String, tag: String) throws -> EntityWrite {
            let snapshot = try JSONEncoder().encode(EntityRecord(entity: "doc", uuid: "d-1", schemaVersion: 1, values: ["p": .string(tag)]))
            return EntityWrite(
                values: ["entity": .string("doc"), "record_uuid": .string("d-1"), "date": .date(date), "snapshot": .bytes(snapshot)], uuid: uuid)
        }
        try await store.write([revision(uuid: "rev-b", tag: "b"), revision(uuid: "rev-a", tag: "a")], entity: EntityStore.revisionEntity)

        #expect(try await store.history(entity: "doc", uuid: "d-1").map { $0.values["p"] } == [.string("a"), .string("b")])
        #expect(try await store.history(entity: "doc", uuid: "d-1").map { $0.values["p"] } == [.string("a"), .string("b")])
    }

    @Test("An export round-trips into another store's import")
    func exportImport() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        var second = makePurchase().values
        second["quantity"] = .int(7)
        try await store.write(second, entity: "purchase", uuid: "p-2")
        try await store.delete(entity: "purchase", uuid: "p-2")

        let dump = try await store.export(entity: "purchase")

        let target = InMemoryDatabase()
        let targetRegistry = SchemaRegistry(database: target)
        try await targetRegistry.publish(makePurchaseDefinition())
        let targetStore = EntityStore(database: target, registry: targetRegistry)
        #expect(try await targetStore.importRecords(dump, entity: "purchase") == 1)
        let imported = try await targetStore.read(entity: "purchase")
        #expect(imported.map(\.uuid) == ["p-1"])
        #expect(imported.first?.values["product_id"] == .string("sku-42"))

        await #expect(throws: SchemaError.invalidValue("purchase")) {
            _ = try await targetStore.importRecords(dump, entity: "profile")
        }
        #expect(try await targetStore.importRecords(dump, entity: "purchase") == 1)
        #expect(try await targetStore.read(entity: "purchase").count == 1)
    }

    @Test("An export to a file writes the same array a page at a time")
    func exportToFile() async throws {
        database.pageLimit = 2
        for index in 0..<5 {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(index))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }
        try await store.delete(entity: "purchase", uuid: "p-4")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await store.export(entity: "purchase", to: url) == 4)
        #expect(try Data(contentsOf: url) == (try await store.export(entity: "purchase")))

        let target = InMemoryDatabase()
        let targetRegistry = SchemaRegistry(database: target)
        try await targetRegistry.publish(makePurchaseDefinition())
        let targetStore = EntityStore(database: target, registry: targetRegistry)
        #expect(try await targetStore.importRecords(try Data(contentsOf: url), entity: "purchase") == 4)
        #expect(try await targetStore.read(entity: "purchase").map(\.uuid).sorted() == ["p-0", "p-1", "p-2", "p-3"])
    }

    @Test("A live query re-yields on every local mutation")
    func liveQuery() async throws {
        var live = store.observe(entity: "purchase", sort: [.init(field: "date")]).makeAsyncIterator()
        #expect(try await live.next() == [])

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(try await live.next()?.map(\.uuid) == ["p-1"])

        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        #expect(try await live.next()?.first?.values["quantity"] == .int(9))

        try await store.delete(entity: "purchase", uuid: "p-1")
        #expect(try await live.next() == [])

        var filtered = store.query("purchase").filter("quantity" > 5).observe().makeAsyncIterator()
        #expect(try await filtered.next() == [])
        var big = makePurchase().values
        big["quantity"] = .int(9)
        try await store.write(big, entity: "purchase", uuid: "p-2")
        #expect(try await filtered.next()?.map(\.uuid) == ["p-2"])
    }

    @Test("List insert and remove are set operations that survive a race")
    func atomicLists() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                ]))
        try await store.write(["name": .string("Ada")], entity: "profile", uuid: "u-1")

        #expect(try await store.insert(["swift", "db"], into: "tags", entity: "profile", uuid: "u-1") == ["swift", "db"])
        #expect(try await store.insert(["db", "ck"], into: "tags", entity: "profile", uuid: "u-1") == ["swift", "db", "ck"])
        #expect(try await store.remove(["db", "ghost"], from: "tags", entity: "profile", uuid: "u-1") == ["swift", "ck"])

        let server = try #require(database.records.first { $0["uuid"] as? String == "u-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]
        #expect(try await store.insert(["new"], into: "tags", entity: "profile", uuid: "u-1") == ["swift", "ck", "new"])

        await #expect(throws: SchemaError.invalidValue("name")) {
            try await store.insert(["x"], into: "name", entity: "profile", uuid: "u-1")
        }
        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await store.remove(["x"], from: "ghost", entity: "profile", uuid: "u-1")
        }
    }

    @Test("A lease admits one holder, renews, expires, and releases")
    func recordLeases() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let granted = try await store.lease(entity: "purchase", uuid: "p-1", owner: "alice", for: 60)
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1") == granted)

        await #expect(throws: SchemaError.self) {
            try await store.lease(entity: "purchase", uuid: "p-1", owner: "bob", for: 60)
        }
        _ = try await store.lease(entity: "purchase", uuid: "p-1", owner: "alice", for: 120)

        try await store.release(entity: "purchase", uuid: "p-1", owner: "bob")
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1") != nil)
        try await store.release(entity: "purchase", uuid: "p-1", owner: "alice")
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1") == nil)

        _ = try await store.lease(entity: "purchase", uuid: "p-1", owner: "alice", for: -1)
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1") == nil)
        _ = try await store.lease(entity: "purchase", uuid: "p-1", owner: "bob", for: 60)
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1")?.owner == "bob")

        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        #expect(try await store.read(entity: "purchase").first?.values["quantity"] == .int(9))
        #expect(try await store.leaseHolder(entity: "purchase", uuid: "p-1")?.owner == "bob")

        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.lease(entity: "purchase", uuid: "ghost", owner: "alice", for: 60)
        }
    }

    @Test("Reads scope to a creator, the public-database pattern")
    func createdByScope() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        var big = makePurchase().values
        big["quantity"] = .int(9)
        try await store.write(big, entity: "purchase", uuid: "p-3")
        stampCreator(uuid: "p-1", creator: "user-a")
        stampCreator(uuid: "p-2", creator: "user-b")
        stampCreator(uuid: "p-3", creator: "user-a")

        #expect(Set(try await store.read(entity: "purchase", createdBy: "user-a").map(\.uuid)) == ["p-1", "p-3"])
        #expect(try await store.read(entity: "purchase", createdBy: "user-b").map(\.uuid) == ["p-2"])
        #expect(try await store.read(entity: "purchase", createdBy: "ghost").isEmpty)

        #expect(try await store.query("purchase").createdBy("user-a").filter("quantity" > 5).count() == 1)
        let grouped = try await store.query("purchase")
            .createdBy("user-a")
            .group {
                $0.filter("quantity", .equals, 3)
                $0.filter("quantity", .equals, 9)
            }
            .all()
        #expect(Set(grouped.map(\.uuid)) == ["p-1", "p-3"])
    }

    @Test("Every query terminal honors the creator scope")
    func createdByScopedTerminals() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        var big = makePurchase().values
        big["quantity"] = .int(9)
        try await store.write(big, entity: "purchase", uuid: "p-3")
        stampCreator(uuid: "p-1", creator: "user-a")
        stampCreator(uuid: "p-2", creator: "user-b")
        stampCreator(uuid: "p-3", creator: "user-a")
        let mine = store.query("purchase").createdBy("user-a")

        #expect(try await mine.sum("quantity") == 12)
        #expect(try await mine.minimum("quantity") == 3)
        #expect(try await mine.maximum("quantity") == 9)
        #expect(try await mine.average("quantity") == 6)
        #expect(try await mine.sum("quantity", by: "product_id") == ["sku-42": 12])
        #expect(try await mine.count(by: "product_id") == ["sku-42": 2])

        #expect(Set(try await mine.paginate(size: 10).records.map(\.uuid)) == ["p-1", "p-3"])
        #expect(try await mine.sort("quantity").page(size: 10).records.map(\.uuid) == ["p-1", "p-3"])
        var streamed: Set<String> = []
        for try await record in mine.stream(pageSize: 1) {
            streamed.insert(record.uuid)
        }
        #expect(streamed == ["p-1", "p-3"])
        #expect(try await mine.explain().first?.server.contains("creatorUserRecordID equals ruser-a") == true)

        #expect(
            try await mine.update { record in
                record.values["comment"] = .string("mine")
            } == 2)
        #expect(try await store.read(entity: "purchase", createdBy: "user-b").first?.values["comment"] == .string("gift"))

        #expect(try await mine.delete() == 2)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("A pattern constraint gates writes by a whole-string regex")
    func patternValidation() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "account",
                fields: [
                    FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_00"), pattern: "[^@]+@[^@]+\\.[a-z]+"),
                    FieldDefinition(name: "codes", type: .stringList, storage: .slot(.stringList, "ls_00"), pattern: "[A-Z]{3}"),
                ]))

        try await store.write(["email": .string("ada@example.com"), "codes": .strings(["ABC", "XYZ"])], entity: "account", uuid: "a-1")

        await #expect(throws: SchemaError.invalidValue("email")) {
            try await store.write(["email": .string("not-an-email")], entity: "account", uuid: "a-2")
        }
        await #expect(throws: SchemaError.invalidValue("codes")) {
            try await store.write(["email": .string("bo@example.com"), "codes": .strings(["ABC", "nope"])], entity: "account", uuid: "a-3")
        }
        await #expect(throws: SchemaError.invalidValue("email")) {
            try await store.write(["email": .string("ada@example.com !!")], entity: "account", uuid: "a-4")
        }

        let numeric = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), pattern: "[0-9]+")
        ])
        #expect(throws: SchemaError.self) { try numeric.validate() }
        let broken = makeDefinition(fields: [
            FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_00"), pattern: "([")
        ])
        #expect(throws: SchemaError.self) { try broken.validate() }
    }

    @Test("Fetch by identifier resolves the entity from the record")
    func fetchByUUID() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let record = try await store.fetch(uuid: "p-1")

        #expect(record?.entity == "purchase")
        #expect(record?.values["quantity"] == makePurchase().values["quantity"])
        #expect(try await store.fetch(uuid: "ghost") == nil)
    }

    @Test("Fetch by identifier hides tombstoned records")
    func fetchByUUIDDeleted() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.delete(entity: "purchase", uuid: "p-1")

        #expect(try await store.fetch(uuid: "p-1") == nil)
    }

    @Test("Fetching by uuid stays scoped to the asked-for entity")
    func fetchStaysScopedToEntity() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ticket",
                fields: [
                    FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"))
                ]))

        try await store.write(makePurchase().values, entity: "purchase", uuid: "shared")
        try await store.write(["label": .string("t")], entity: "ticket", uuid: "shared")

        #expect(try await store.fetch(entity: "purchase", uuids: ["shared"]).isEmpty)
        #expect(try await store.fetch(entity: "ticket", uuids: ["shared"]).map(\.uuid) == ["shared"])
        await #expect(throws: SchemaError.self) {
            try await store.update(entity: "purchase", uuid: "shared") { $0.values["quantity"] = .int(1) }
        }
    }

    @Test("Reap tombstones expired records")
    func reap() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ping",
                fields: [
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"))
                ], envelopeDate: "date", ttl: 3_600))

        try await store.write(["date": .date(Date(timeIntervalSince1970: 1_000))], entity: "ping", uuid: "old")
        try await store.write(["date": .date(Date(timeIntervalSince1970: 100_000))], entity: "ping", uuid: "new")

        let reaped = try await store.reap(entity: "ping", asOf: Date(timeIntervalSince1970: 50_000))
        #expect(reaped == 1)
        let records = try await store.read(entity: "ping")
        #expect(records.map(\.uuid) == ["new"])
    }

    @Test("Projection fetches only the requested fields")
    func projection() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let slim = try await store.read(entity: "purchase", fields: ["product_id"])
        #expect(slim.first?.values["product_id"] == .string("sku-42"))
        #expect(slim.first?.values["quantity"] == nil)
        #expect(slim.first?.values["comment"] == nil)

        let withPayload = try await store.read(entity: "purchase", fields: ["comment"])
        #expect(withPayload.first?.values["comment"] == .string("gift"))
    }

    @Test("Projection auto-includes filtered fields")
    func projectionWithFilter() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        let records = try await store.read(entity: "purchase", filters: [filter], fields: ["product_id"])
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Explain reveals the server and client sides of a query")
    func explain() async throws {
        let filters = [
            EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42")),
            EntityStore.Filter(field: "comment", op: .contains, value: .string("gif")),
        ]
        let plan = try await store.explain(entity: "purchase", filters: filters, sort: [EntityStore.Sort(field: "date")])
        #expect(plan.server.contains("s_00 equals sku-42"))
        #expect(plan.client.contains("comment contains gif"))
        #expect(plan.sort == ["t_00 asc"])
        #expect(plan.description.contains("SERVER s_00 equals sku-42"))
    }

    @Test("Paginated reads apply client-side filters across pages")
    func paginationWithClientFilter() async throws {
        for index in 0..<4 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            values["comment"] = .string(index % 2 == 0 ? "gift" : "other")
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        var uuids: [String] = []
        var cursor: EntityCursor?
        repeat {
            let page = try await store.read(entity: "purchase", filters: [filter], limit: 1, after: cursor)
            uuids += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil
        #expect(uuids == ["p-0", "p-2"])
    }

    @Test("Stream pages through every record in order")
    func stream() async throws {
        for index in 0..<5 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        var uuids: [String] = []
        for try await record in store.stream(entity: "purchase", pageSize: 2) {
            uuids.append(record.uuid)
        }
        #expect(uuids == ["p-0", "p-1", "p-2", "p-3", "p-4"])
    }

    @Test("updateAll rewrites every matching record")
    func updateAll() async throws {
        for index in 0..<3 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }
        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))
        let updated = try await store.updateAll(entity: "purchase", filters: [filter]) { record in
            record.values["quantity"] = .int(99)
        }
        #expect(updated == 3)

        let records = try await store.read(entity: "purchase")
        #expect(records.allSatisfy { $0.values["quantity"] == .int(99) })
    }

    @Test("updateAll patches across server pages and counts a uuid once across OR branches")
    func updateAllAcrossPages() async throws {
        for index in 0..<7 {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(index))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }
        database.pageLimit = 2

        let updated = try await store.updateAll(
            entity: "purchase",
            any: [
                [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))],
                [EntityStore.Filter(field: "quantity", op: .lessThan, value: .int(3))],
            ]
        ) { record in
            record.values["comment"] = .string("swept")
        }
        #expect(updated == 7)

        let records = try await store.read(entity: "purchase")
        #expect(records.count == 7)
        #expect(records.allSatisfy { $0.values["comment"] == .string("swept") })
    }

    @Test("A batched update patches every named record and rejects a missing one")
    func updateBatch() async throws {
        for index in 0..<3 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }

        try await store.update(entity: "purchase", uuids: ["p-0", "p-2", "p-0"]) { record in
            record.values["quantity"] = .int(record.uuid == "p-2" ? 20 : 10)
        }
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-0", "p-1", "p-2"]).map { $0.values["quantity"] } == [.int(10), .int(3), .int(20)])

        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.update(entity: "purchase", uuids: ["p-1", "ghost"]) { record in
                record.values["quantity"] = .int(99)
            }
        }
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).first?.values["quantity"] == .int(3))
    }

    @Test("deleteAll tombstones every matching record")
    func deleteAll() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write(other, entity: "purchase", uuid: "p-2")

        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))
        let deleted = try await store.deleteAll(entity: "purchase", filters: [filter])
        #expect(deleted == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("Transaction applies every step and commits")
    func transaction() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        let txn = try await store.transaction { draft in
            draft.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
            draft.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        }

        #expect(try await store.read(entity: "purchase").count == 2)
        let committed = try await store.read(entity: EntityStore.transactionEntity)
        #expect(committed.map(\.uuid) == [txn])
        #expect(committed.first?.values["status"] == .string("committed"))
    }

    @Test("A transaction mixes writes and deletes in order")
    func transactionDeletes() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        try await store.transaction { draft in
            draft.write(makePurchase().values, entity: "purchase", uuid: "p-2")
            draft.delete(entity: "purchase", uuid: "p-1")
        }

        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
        let committed = try await store.read(entity: EntityStore.transactionEntity)
        guard case .bytes(let data)? = committed.first?.values["steps"] else {
            Issue.record("missing steps")
            return
        }
        let steps = try JSONDecoder().decode([TransactionStep].self, from: data)
        #expect(steps.map(\.kind) == [.write, .delete])
    }

    @Test("Interleaved entities and grouped deletes land the same records")
    func transactionBatching() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await registry.publish(makeSeatDefinition())

        try await store.transaction { draft in
            draft.write(makePurchase().values, entity: "purchase", uuid: "p-1")
            draft.write(["row": .string("a"), "number": .int(1)], entity: "seat", uuid: "s-1")
            draft.write(makePurchase().values, entity: "purchase", uuid: "p-2")
            draft.write(["row": .string("a"), "number": .int(2)], entity: "seat", uuid: "s-2")
            var repeated = makePurchase().values
            repeated["quantity"] = .int(9)
            draft.write(repeated, entity: "purchase", uuid: "p-1")
        }
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-1", "p-2"])
        #expect(try await store.read(entity: "seat").map(\.uuid).sorted() == ["s-1", "s-2"])
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).first?.values["quantity"] == .int(9))

        try await store.transaction { draft in
            draft.delete(entity: "purchase", uuid: "p-1")
            draft.delete(entity: "purchase", uuid: "p-2")
            draft.delete(entity: "seat", uuid: "s-1")
        }
        #expect(try await store.read(entity: "purchase").isEmpty)
        #expect(try await store.read(entity: "seat").map(\.uuid) == ["s-2"])
        try await store.restore(entity: "purchase", uuid: "p-1")
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).first?.values["quantity"] == .int(9))
    }

    @Test("A transaction patches existing records with update steps")
    func transactionUpdates() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        try await store.transaction { draft in
            draft.update(["quantity": .int(9)], entity: "purchase", uuid: "p-1")
        }

        let patched = try #require(try await store.read(entity: "purchase").first)
        #expect(patched.values["quantity"] == .int(9))
        #expect(patched.values["product_id"] == .string("sku-42"))

        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.transaction { draft in
                draft.update(["quantity": .int(1)], entity: "purchase", uuid: "ghost")
            }
        }
        let pending = try await store.read(
            entity: EntityStore.transactionEntity, filters: [.init(field: "status", op: .equals, value: .string("pending"))])
        #expect(pending.count == 1)
    }

    @Test("A run of update steps lands as one batch, the last patch of a record winning")
    func transactionUpdateBatching() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        try await registry.publish(makeSeatDefinition())
        try await store.write(["row": .string("a"), "number": .int(1)], entity: "seat", uuid: "s-1")

        try await store.transaction { draft in
            draft.update(["quantity": .int(1)], entity: "purchase", uuid: "p-1")
            draft.update(["label": .string("aisle")], entity: "seat", uuid: "s-1")
            draft.update(["quantity": .int(2)], entity: "purchase", uuid: "p-2")
            draft.update(["quantity": .int(9), "product_id": .string("sku-9")], entity: "purchase", uuid: "p-1")
        }

        let patched = try await store.fetch(entity: "purchase", uuids: ["p-1", "p-2"])
        #expect(patched.map { $0.values["quantity"] } == [.int(9), .int(2)])
        #expect(patched.first?.values["product_id"] == .string("sku-9"))
        #expect(try await store.fetch(entity: "seat", uuids: ["s-1"]).first?.values["label"] == .string("aisle"))

        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.transaction { draft in
                draft.update(["quantity": .int(5)], entity: "purchase", uuid: "p-2")
                draft.update(["quantity": .int(5)], entity: "purchase", uuid: "ghost")
            }
        }
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-2"]).first?.values["quantity"] == .int(2))
    }

    @Test("Compaction drops committed transaction envelopes and leaves pending ones")
    func compactTransactions() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await store.transaction { draft in
            draft.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        }
        let steps = try JSONEncoder().encode([TransactionStep(entity: "purchase", uuid: "p-2", values: makePurchase().values)])
        try await store.write(
            ["status": .string("pending"), "date": .date(Date(timeIntervalSince1970: 1_000)), "steps": .bytes(steps)], entity: EntityStore.transactionEntity,
            uuid: "t-pending")

        #expect(try await store.compactTransactions(olderThan: Date(timeIntervalSince1970: 0)) == 0)
        #expect(try await store.compactTransactions(olderThan: Date().addingTimeInterval(60)) == 1)
        #expect(try await store.read(entity: EntityStore.transactionEntity).map(\.uuid) == ["t-pending"])
        #expect(try await store.repairTransactions() == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid).sorted() == ["p-1", "p-2"])
    }

    @Test("Steps persisted before deletes existed decode as writes")
    func legacyStepDecoding() throws {
        let legacy = Data(#"{"entity":"purchase","uuid":"p-1","values":{}}"#.utf8)
        let step = try JSONDecoder().decode(TransactionStep.self, from: legacy)
        #expect(step.kind == .write)
    }

    @Test("Repair completes an interrupted transaction")
    func repair() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        let steps = try JSONEncoder().encode([TransactionStep(entity: "purchase", uuid: "p-9", values: makePurchase().values)])
        try await store.write(
            ["status": .string("pending"), "date": .date(Date(timeIntervalSince1970: 1_000)), "steps": .bytes(steps)], entity: EntityStore.transactionEntity,
            uuid: "t-1")

        let repaired = try await store.repairTransactions()
        #expect(repaired == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-9"])

        let committed = try await store.read(entity: EntityStore.transactionEntity)
        #expect(committed.first?.values["status"] == .string("committed"))
        #expect(try await store.repairTransactions() == 0)
    }

    @Test("Preload warms the cache for every published entity")
    func preload() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "alpha",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "beta",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))

        let fresh = SchemaRegistry(database: database)
        let preloaded = try await fresh.preload()
        #expect(preloaded == 3)
        #expect(Set(await fresh.definitions().map(\.entity)) == ["purchase", "alpha", "beta"])
    }

    @Test("Untrusted writers are filtered out of reads")
    func trustedWriters() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        stampCreator(uuid: "p-1", creator: "good")
        stampCreator(uuid: "p-2", creator: "evil")

        let guarded = EntityStore(database: database, registry: registry, trustedWriters: ["good"])
        let records = try await guarded.read(entity: "purchase")
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Join resolves references, orphans find broken ones, cascade deletes children")
    func relations() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1")], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Lost"), "author_id": .string("a-9")], entity: "book", uuid: "b-2")

        let books = try await store.read(entity: "book")
        let parents = try await store.join(entity: "book", records: books, field: "author_id")
        #expect(parents["a-1"]?.values["name"] == .string("Twain"))

        let orphans = try await store.orphans(entity: "book", field: "author_id")
        #expect(orphans.map(\.uuid) == ["b-2"])

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        let remaining = try await store.read(entity: "book")
        #expect(remaining.map(\.uuid) == ["b-2"])
    }

    @Test("A tombstoned parent orphans its children, and a projection trims what comes back")
    func orphansOfTombstonedParent() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))
        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1")], entity: "book", uuid: "b-1")

        #expect(try await store.orphans(entity: "book", field: "author_id").isEmpty)

        try await store.delete(entity: "author", uuid: "a-1")
        let orphaned = try await store.orphans(entity: "book", field: "author_id")
        #expect(orphaned.map(\.uuid) == ["b-1"])
        #expect(orphaned.first?.values["title"] == .string("Tom"))

        let projected = try await store.orphans(entity: "book", field: "author_id", fields: [])
        #expect(projected.map(\.uuid) == ["b-1"])
        #expect(projected.first?.values["title"] == nil)
        #expect(projected.first?.values["author_id"] == .string("a-1"))
    }

    @Test("Cascade delete reaches entities not yet cached in the registry")
    func cascadeUncached() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))
        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1")], entity: "book", uuid: "b-1")

        let fresh = EntityStore(database: database, registry: SchemaRegistry(database: database))
        try await fresh.delete(entity: "author", uuid: "a-1", cascade: true)

        #expect(try await store.read(entity: "book").isEmpty)
    }

    @Test("List references join across parents, report orphans, and detach on cascade delete")
    func manyToMany() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne")], entity: "author", uuid: "a-2")
        try await store.write(["title": .string("Duo"), "author_ids": .strings(["a-1", "a-2"])], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Solo"), "author_ids": .strings(["a-2"])], entity: "book", uuid: "b-2")
        try await store.write(["title": .string("Lost"), "author_ids": .strings(["a-2", "a-9"])], entity: "book", uuid: "b-3")

        let books = try await store.read(entity: "book")
        let parents = try await store.join(entity: "book", records: books, field: "author_ids")
        #expect(parents.keys.sorted() == ["a-1", "a-2"])

        let orphans = try await store.orphans(entity: "book", field: "author_ids")
        #expect(orphans.map(\.uuid) == ["b-3"])

        try await store.delete(entity: "author", uuid: "a-2", cascade: true)
        let remaining = try await store.read(entity: "book")
        #expect(Set(remaining.map(\.uuid)) == ["b-1", "b-2", "b-3"])
        let values = Dictionary(uniqueKeysWithValues: remaining.map { ($0.uuid, $0.values["author_ids"]) })
        #expect(values["b-1"] == .strings(["a-1"]))
        #expect(values["b-2"] == .strings([]))
        #expect(values["b-3"] == .strings(["a-9"]))
    }

    @Test("A cascade probes every referring entity in one round")
    func cascadeProbesInParallel() async throws {
        let backing = InMemoryDatabase()
        let counting = CountingFetches(backing: backing)
        let registry = SchemaRegistry(database: counting)
        let store = EntityStore(database: counting, registry: registry)
        let children = ["book", "note", "photo"]

        try await registry.publish(
            makeDefinition(entity: "author", fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))]))
        for child in children {
            try await registry.publish(
                makeDefinition(
                    entity: child,
                    fields: [FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_00"), references: "author")]))
        }

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        for child in children {
            try await store.write(["author_id": .string("a-1")], entity: child, uuid: "\(child)-1")
        }

        counting.reset()
        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        #expect(counting.peakInFlight >= children.count)
        for child in children {
            #expect(try await store.read(entity: child).isEmpty)
        }
    }

    @Test("A child referred to through two fields is removed from its view once")
    func cascadeDedupesAcrossFields() async throws {
        try await registry.publish(
            makeDefinition(entity: "author", fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))]))
        try await registry.publish(
            makeDefinition(
                entity: "note",
                fields: [
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_00"), references: "author"),
                    FieldDefinition(name: "editor_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: [AggregateView(name: "total", bucket: .lifetime)]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(
            ["author_id": .string("a-1"), "editor_id": .string("a-1"), "date": .date(Date())], entity: "note", uuid: "n-1")

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        #expect(try await store.read(entity: "note").isEmpty)

        let counts = database.records.filter { $0.recordType == "Aggregate" }
            .flatMap { record in (0..<Aggregate.cellCount).map { record[Aggregate.countCell($0)] as? Int64 ?? 0 } }
        #expect(counts.allSatisfy { $0 >= 0 })
        #expect(counts.reduce(0, +) == 0)
    }

    @Test("A cascade detaches every dead key of a record in one rewrite")
    func detachesManyKeysAtOnce() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "shelf",
                fields: [
                    FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "book_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "book"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne")], entity: "author", uuid: "a-2")
        try await store.write(["title": .string("One"), "author_id": .string("a-1")], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Two"), "author_id": .string("a-1")], entity: "book", uuid: "b-2")
        try await store.write(["title": .string("Three"), "author_id": .string("a-2")], entity: "book", uuid: "b-3")
        try await store.write(["label": .string("Both"), "book_ids": .strings(["b-1", "b-2"])], entity: "shelf", uuid: "s-1")
        try await store.write(["label": .string("Mixed"), "book_ids": .strings(["b-1", "b-3"])], entity: "shelf", uuid: "s-2")
        try await store.write(["label": .string("Live"), "book_ids": .strings(["b-3"])], entity: "shelf", uuid: "s-3")

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)

        #expect(try await store.read(entity: "book").map(\.uuid) == ["b-3"])
        let shelves = try await store.read(entity: "shelf")
        let values = Dictionary(uniqueKeysWithValues: shelves.map { ($0.uuid, $0.values["book_ids"]) })
        #expect(values["s-1"] == .strings([]))
        #expect(values["s-2"] == .strings(["b-3"]))
        #expect(values["s-3"] == .strings(["b-3"]))
    }

    @Test("Children reads the records referencing a parent, scalar and list alike")
    func children() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                    FieldDefinition(name: "editor_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1"), "editor_ids": .strings(["a-2"])], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Huck"), "author_id": .string("a-2"), "editor_ids": .strings(["a-1", "a-2"])], entity: "book", uuid: "b-2")

        let written = try await store.children(entity: "book", of: "a-1", via: "author_id")
        #expect(written.map(\.uuid) == ["b-1"])

        let edited = try await store.children(entity: "book", of: "a-1", via: "editor_ids")
        #expect(edited.map(\.uuid) == ["b-2"])

        await #expect(throws: SchemaError.unknownField("title")) {
            _ = try await store.children(entity: "book", of: "a-1", via: "title")
        }
    }

    @Test("An enforcing store rejects writes whose references name missing parents")
    func enforcedReferences() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                    FieldDefinition(name: "editor_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))
        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")

        let enforcing = EntityStore(database: database, registry: registry, enforceReferences: true)
        try await enforcing.write(["title": .string("Tom"), "author_id": .string("a-1"), "editor_ids": .strings(["a-1"])], entity: "book", uuid: "b-1")

        await #expect(throws: SchemaError.brokenReference(field: "author_id", key: "a-9")) {
            try await enforcing.write(["title": .string("Lost"), "author_id": .string("a-9")], entity: "book", uuid: "b-2")
        }
        await #expect(throws: SchemaError.brokenReference(field: "editor_ids", key: "a-9")) {
            let values: [String: RecordValue] = ["title": .string("Lost"), "author_id": .string("a-1"), "editor_ids": .strings(["a-1", "a-9"])]
            try await enforcing.write(values, entity: "book", uuid: "b-3")
        }

        try await store.write(["title": .string("Free"), "author_id": .string("a-9")], entity: "book", uuid: "b-4")
        #expect(Set(try await store.read(entity: "book").map(\.uuid)) == ["b-1", "b-4"])
    }

    @Test("An exclusive reference admits one holder, allows re-writes, rejects a second suitor")
    func exclusiveReference() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "person",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "passport",
                fields: [
                    FieldDefinition(name: "number", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "person_id", type: .string, storage: .slot(.string, "s_01"), references: "person", exclusive: true),
                ]))
        try await store.write(["name": .string("Ada")], entity: "person", uuid: "h-1")

        try await store.write(["number": .string("111"), "person_id": .string("h-1")], entity: "passport", uuid: "d-1")
        try await store.write(["number": .string("112"), "person_id": .string("h-1")], entity: "passport", uuid: "d-1")

        await #expect(throws: SchemaError.duplicateReference(field: "person_id", key: "h-1")) {
            try await store.write(["number": .string("222"), "person_id": .string("h-1")], entity: "passport", uuid: "d-2")
        }
        await #expect(throws: SchemaError.duplicateReference(field: "person_id", key: "h-2")) {
            try await store.write(
                [
                    EntityWrite(values: ["number": .string("333"), "person_id": .string("h-2")], uuid: "d-3"),
                    EntityWrite(values: ["number": .string("444"), "person_id": .string("h-2")], uuid: "d-4"),
                ], entity: "passport")
        }
    }

    @Test("An update cannot move an exclusive reference onto a taken key, and a re-key frees the old one")
    func exclusiveReferenceUpdate() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "person",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "passport",
                fields: [
                    FieldDefinition(name: "number", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "person_id", type: .string, storage: .slot(.string, "s_01"), references: "person", exclusive: true),
                ]))
        try await store.write(["number": .string("111"), "person_id": .string("h-1")], entity: "passport", uuid: "d-1")
        try await store.write(["number": .string("222"), "person_id": .string("h-2")], entity: "passport", uuid: "d-2")

        await #expect(throws: SchemaError.duplicateReference(field: "person_id", key: "h-1")) {
            try await store.update(entity: "passport", uuid: "d-2") { record in
                record.values["person_id"] = .string("h-1")
            }
        }

        try await store.update(entity: "passport", uuid: "d-2") { record in
            record.values["person_id"] = .string("h-3")
        }
        try await store.write(["number": .string("333"), "person_id": .string("h-2")], entity: "passport", uuid: "d-3")
    }

    @Test("A multi-field join resolves every reference in one call")
    func multiJoin() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "publisher",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                    FieldDefinition(name: "publisher_id", type: .string, storage: .slot(.string, "s_01"), references: "publisher"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne")], entity: "author", uuid: "a-2")
        try await store.write(["name": .string("Salt")], entity: "publisher", uuid: "pub-1")
        try await store.write(
            ["title": .string("Duo"), "author_ids": .strings(["a-1", "a-2"]), "publisher_id": .string("pub-1")], entity: "book", uuid: "b-1")

        let books = try await store.read(entity: "book")
        let joined = try await store.join(entity: "book", records: books, fields: ["author_ids", "publisher_id"])

        #expect(joined["author_ids"]?.keys.sorted() == ["a-1", "a-2"])
        #expect(joined["publisher_id"]?["pub-1"]?.values["name"] == .string("Salt"))
    }

    @Test("A path join walks the reference chain level by level")
    func pathJoin() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "agency",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "agency_id", type: .string, storage: .slot(.string, "s_01"), references: "agency"),
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))

        try await store.write(["name": .string("Salt")], entity: "agency", uuid: "g-1")
        try await store.write(["name": .string("Twain"), "agency_id": .string("g-1")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne"), "agency_id": .string("g-1")], entity: "author", uuid: "a-2")
        try await store.write(["title": .string("Duo"), "author_ids": .strings(["a-1", "a-2"])], entity: "book", uuid: "b-1")

        let books = try await store.read(entity: "book")
        let levels = try await store.join(entity: "book", records: books, path: ["author_ids", "agency_id"])

        #expect(levels.count == 2)
        #expect(levels[0].keys.sorted() == ["a-1", "a-2"])
        #expect(levels[1]["g-1"]?.values["name"] == .string("Salt"))

        await #expect(throws: SchemaError.unknownField("name")) {
            _ = try await store.join(entity: "book", records: books, path: ["author_ids", "name"])
        }
    }

    @Test("Generated Swift source mirrors the definition")
    func codegen() {
        let source = DefinitionCodeGenerator().source(for: makePurchaseDefinition())
        #expect(source.contains("struct Purchase: EntityRepresentable {"))
        #expect(source.contains("var productId: String?"))
        #expect(source.contains("productId = record[\"product_id\"]"))
        #expect(source.contains("var date: Date?"))
        #expect(source.contains("var recordValues: [String: RecordValue] {"))
        #expect(source.contains("values[\"product_id\"] = productId?.recordValue"))
    }

    @Test("The generator turns a definition's JSON into a complete source file")
    func codegenJSON() throws {
        let source = try DefinitionCodeGenerator().source(forJSON: JSONEncoder().encode(makePurchaseDefinition()))
        #expect(source.hasPrefix("// Generated by scoutdb-codegen"))
        #expect(source.contains("import ScoutDB"))
        #expect(source.contains("struct Purchase: EntityRepresentable {"))

        let broken = makeDefinition(fields: [FieldDefinition(name: "x", type: .string, storage: .slot(.int, "i_00"))])
        #expect(throws: SchemaError.self) {
            _ = try DefinitionCodeGenerator().source(forJSON: JSONEncoder().encode(broken))
        }
    }

    @Test("Typed lists round-trip through the record subscript")
    func typedListSubscript() {
        var record = EntityRecord(entity: "profile", uuid: "u-1", schemaVersion: 1, values: [:])
        record["tags"] = ["a", "b"]
        record["counts"] = [Int64(1), 2]
        record["rates"] = [1.5, 2.5]
        record["days"] = [Date(timeIntervalSince1970: 0)]

        #expect(record.values["tags"] == .strings(["a", "b"]))
        #expect(record.values["counts"] == .ints([1, 2]))
        #expect(record.values["rates"] == .doubles([1.5, 2.5]))
        #expect(record.values["days"] == .dates([Date(timeIntervalSince1970: 0)]))

        let counts: [Int64]? = record["counts"]
        #expect(counts == [1, 2])
        let plain: [Int]? = record["counts"]
        #expect(plain == [1, 2])
        let rates: [Double]? = record["rates"]
        #expect(rates == [1.5, 2.5])
        let days: [Date]? = record["days"]
        #expect(days == [Date(timeIntervalSince1970: 0)])
        let mismatched: [Int64]? = record["tags"]
        #expect(mismatched == nil)
    }

    private func stampCreator(uuid: String, creator: String) {
        for record in database.records where record.recordType == "Entity" && record.recordID.recordName == uuid {
            record.overrideCreator(creator)
        }
    }
}
