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

        let updated = try await store.updateAll(entity: "purchase", any: [[]]) { record in
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
            try await store.updateAll(entity: "purchase", any: [[]]) { record in
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
            guard case .int(let quantity)? = record.values["quantity"] else {
                return
            }
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
                uniqueKeys: [["code"]]))
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
        try await registry.publish(
            EntityDefinition(
                entity: "badge", version: 1,
                fields: [
                    FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                uniqueKeys: [["code"]],
                views: [AggregateView(name: "total", sum: "amount")]))
        let counting = CountingFetches(backing: database)
        let claimed = EntityStore(database: counting, registry: registry)
        try await claimed.write(["code": .string("gold"), "amount": .double(1)], entity: "badge", uuid: "b-1")

        counting.reset()
        try await claimed.update(entity: "badge", uuid: "b-1") { record in
            record.values["code"] = .string("silver")
            record.values["amount"] = .double(2)
        }

        #expect(counting.peakInFlight == 2)
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

        let first = try await store.read(entity: "purchase", orderedBy: "date", limit: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let cursor = try #require(first.cursor)

        let second = try await store.read(entity: "purchase", orderedBy: "date", limit: 2, after: cursor)
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
        let firstCursor = try #require(first.cursor)
        let second = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 2, after: firstCursor)
        #expect(second.records.map(\.uuid) == ["p-3", "p-0"])

        let top = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3)
        #expect(top.records.map(\.uuid) == ["p-0", "p-2", "p-3"])
        let topCursor = try #require(top.cursor)
        let rest = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3, after: topCursor)
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
        let id = try await store.query("purchase").filter("quantity" > 1).subscribe()
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

    @Test("Retiring an entity hides its schema; a republish revives it")
    func retireEntity() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        #expect(try await store.deleteAll(entity: "purchase", any: [[]]) == 2)
        try await registry.retire(entity: "purchase")
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

    @Test("A push that is not a query notification resolves to no record")
    func pushEvents() async throws {
        #expect(try await store.record(fromPush: ["aps": ["alert": "hi"]]) == nil)

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(try await store.record(uuid: "p-1", pushedFields: [:])?.values["product_id"] == .string("sku-42"))

        try await store.delete(entity: "purchase", uuid: "p-1")
        #expect(try await store.record(uuid: "p-1", pushedFields: [:]) == nil)
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

    @Test("Mutations treat a tombstoned record as absent, but a write to its uuid revives it")
    func mutationsSkipTombstones() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "t-1")
        try await store.delete(entity: "purchase", uuid: "t-1")

        await #expect(throws: SchemaError.notFound("t-1")) {
            try await store.update(entity: "purchase", uuid: "t-1") { $0.values["quantity"] = .int(1) }
        }

        try await store.write(makePurchase().values, entity: "purchase", uuid: "t-1")
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["t-1"])
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
            .filter("quantity" == 3 || "quantity" == 9)
            .take(100)
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
        #expect(try await mine.min("quantity") == 3)
        #expect(try await mine.max("quantity") == 9)
        #expect(try await mine.average("quantity") == 6)
        #expect(try await mine.sum("quantity", by: "product_id") == ["sku-42": 12])
        #expect(try await mine.count(by: "product_id") == ["sku-42": 2])

        #expect(try await mine.sort("quantity").page(size: 10).records.map(\.uuid) == ["p-1", "p-3"])

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

    @Test("A query splits into server predicates, client matchers and slot sorts")
    func queryPlanning() async throws {
        let filters = [
            EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42")),
            EntityStore.Filter(field: "comment", op: .contains, value: .string("gif")),
        ]
        let definition = try await registry.definition(for: "purchase")
        let (server, client) = try store.split(filters, entity: "purchase", using: definition)
        #expect(server.contains(ServerFilter(field: "s_00", op: .equals, value: .string("sku-42"))))
        #expect(client == [filters[1]])
        #expect(try store.serverSort([EntityStore.Sort(field: "date")], using: definition) == [ServerSort(field: "t_00", ascending: true)])
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
        var cursor: FieldCursor?
        repeat {
            let page = try await store.read(entity: "purchase", any: [[filter]], orderedBy: "date", limit: 1, after: cursor)
            uuids += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil
        #expect(uuids == ["p-0", "p-2"])
    }

    @Test("updateAll rewrites every matching record")
    func updateAll() async throws {
        for index in 0..<3 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }
        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))
        let updated = try await store.updateAll(entity: "purchase", any: [[filter]]) { record in
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
        let deleted = try await store.deleteAll(entity: "purchase", any: [[filter]])
        #expect(deleted == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
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

    @Test("Join resolves references, and cascade deletes children")
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

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        let remaining = try await store.read(entity: "book")
        #expect(remaining.map(\.uuid) == ["b-2"])
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

    @Test("List references join across parents, and detach on cascade delete")
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
                ], views: [AggregateView(name: "total")]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(
            ["author_id": .string("a-1"), "editor_id": .string("a-1"), "date": .date(Date())], entity: "note", uuid: "n-1")

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        #expect(try await store.read(entity: "note").isEmpty)

        let counts = database.records.filter { $0.recordType == "Aggregate" }.map(\.cellCount)
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
