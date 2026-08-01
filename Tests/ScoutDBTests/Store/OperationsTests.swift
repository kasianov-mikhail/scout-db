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
        let rest = try await store.read(
            entity: "purchase",
            orderedBy: "quantity",
            descending: true,
            limit: 3,
            after: topCursor
        )
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
                ]
            )
        )
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
                ]
            )
        )
        try await store.write(
            ["name": .string("Ada"), "score": .int(10), "tags": .strings(["swift", "db"])],
            entity: "profile",
            uuid: "u-1"
        )
        try await store.write(
            ["name": .string("Bo"), "score": .int(5), "tags": .strings(["db"])],
            entity: "profile",
            uuid: "u-2"
        )
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
    }

    @Test("Retiring an entity hides its schema; a republish revives it")
    func retireEntity() async throws {
        try await registry.retire(entity: "purchase")
        await #expect(throws: SchemaError.unknownEntity("purchase")) {
            _ = try await store.read(entity: "purchase")
        }

        let fresh = SchemaRegistry(database: database)
        try await fresh.loadAll()
        #expect(await fresh.schemas().isEmpty)

        try await registry.publish(makePurchaseDefinition())
        #expect(try await store.read(entity: "purchase").isEmpty)

        await #expect(throws: SchemaError.unknownEntity("ghost")) {
            try await registry.retire(entity: "ghost")
        }
    }

    @Test("A batch write surfaces the error the database raised")
    func batchWriteError() async throws {
        database.writeErrors = [CKError(.partialFailure)]

        do {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
            Issue.record("Expected a CKError")
        } catch let error as CKError {
            #expect(error.code == .partialFailure)
        }
    }

    @Test("Mutations treat an unwritten uuid as absent, and a write claims it")
    func mutationsSkipUnwritten() async throws {
        await #expect(throws: SchemaError.notFound("t-1")) {
            try await store.update(entity: "purchase", uuid: "t-1") { $0.values["quantity"] = .int(1) }
        }

        try await store.write(makePurchase().values, entity: "purchase", uuid: "t-1")
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["t-1"])
    }

    @Test("A pattern constraint gates writes by a whole-string regex")
    func patternValidation() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "account",
                fields: [
                    FieldDefinition(
                        name: "email",
                        type: .string,
                        storage: .slot(.string, "s_00"),
                        pattern: "[^@]+@[^@]+\\.[a-z]+"
                    ),
                    FieldDefinition(
                        name: "codes",
                        type: .stringList,
                        storage: .slot(.stringList, "ls_00"),
                        pattern: "[A-Z]{3}"
                    ),
                ]
            )
        )

        try await store.write(
            ["email": .string("ada@example.com"), "codes": .strings(["ABC", "XYZ"])],
            entity: "account",
            uuid: "a-1"
        )

        await #expect(throws: SchemaError.invalidValue("email")) {
            try await store.write(["email": .string("not-an-email")], entity: "account", uuid: "a-2")
        }
        await #expect(throws: SchemaError.invalidValue("codes")) {
            try await store.write(
                ["email": .string("bo@example.com"), "codes": .strings(["ABC", "nope"])],
                entity: "account",
                uuid: "a-3"
            )
        }
        await #expect(throws: SchemaError.invalidValue("email")) {
            try await store.write(["email": .string("ada@example.com !!")], entity: "account", uuid: "a-4")
        }

        let numeric = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), pattern: "[0-9]+")
        ]
        )
        #expect(throws: SchemaError.self) { try numeric.validate() }
        let broken = makeDefinition(fields: [
            FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_00"), pattern: "([")
        ]
        )
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

    @Test("Fetching by uuid stays scoped to the asked-for entity")
    func fetchStaysScopedToEntity() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ticket",
                fields: [
                    FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"))
                ]
            )
        )

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
        #expect(
            try store.serverSort([EntityStore.Sort(field: "date")], using: definition) == [
                ServerSort(field: "t_00", ascending: true)
            ]
        )
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
            let page = try await store.read(
                entity: "purchase",
                any: [[filter]],
                orderedBy: "date",
                limit: 1,
                after: cursor
            )
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
        #expect(
            try await store.fetch(entity: "purchase", uuids: ["p-0", "p-1", "p-2"]).map { $0.values["quantity"] } == [
                .int(10), .int(3), .int(20),
            ]
        )

        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.update(entity: "purchase", uuids: ["p-1", "ghost"]) { record in
                record.values["quantity"] = .int(99)
            }
        }
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).first?.values["quantity"] == .int(3))
    }

    @Test("A bulk load warms the cache for every published entity")
    func loadAll() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "alpha",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]
            )
        )
        try await registry.publish(
            makeDefinition(
                entity: "beta",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]
            )
        )

        let fresh = SchemaRegistry(database: database)
        let loaded = try await fresh.loadAll()
        #expect(loaded == 3)
        #expect(Set(await fresh.schemas().map(\.entity)) == ["purchase", "alpha", "beta"])
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
}
