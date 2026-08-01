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

@Suite("EntityStore")
struct EntityStoreTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("Write persists a single Entity record")
    func write() async throws {
        try await store.write([EntityWrite(values: makePurchase().values, uuid: "p-1")], entity: "purchase")
        #expect(database.records.filter { $0.recordType == "Entity" }.count == 1)
    }

    @Test("A batched write persists every Entity and returns uuids in batch order")
    func batchWrite() async throws {
        let uuids = try await store.write(
            [
                EntityWrite(values: makePurchase(uuid: "p-1").values, uuid: "p-1"),
                EntityWrite(values: makePurchase(uuid: "p-2").values, uuid: "p-2"),
                EntityWrite(values: makePurchase(uuid: "p-3").values, uuid: "p-3"),
            ],
            entity: "purchase"
        )

        #expect(uuids == ["p-1", "p-2", "p-3"])
        #expect(database.records.filter { $0.recordType == "Entity" }.count == 3)
    }

    @Test("An empty batch writes nothing")
    func emptyBatch() async throws {
        let uuids = try await store.write([], entity: "purchase")
        #expect(uuids.count == 0)
        #expect(database.records.filter { $0.recordType == "Entity" }.count == 0)
    }

    @Test("Read restores entity records")
    func read() async throws {
        let purchase = makePurchase()
        try await store.write([EntityWrite(values: purchase.values, uuid: "p-1")], entity: "purchase")
        let records = try await store.read(entity: "purchase")
        #expect(records == [purchase])
    }

    @Test("Read filters on a slot field")
    func filteredRead() async throws {
        try await store.write([EntityWrite(values: makePurchase(uuid: "p-1").values, uuid: "p-1")], entity: "purchase")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write([EntityWrite(values: other, uuid: "p-2")], entity: "purchase")

        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-7"))
        let records = try await store.read(entity: "purchase", any: [[filter]])
        #expect(records.map(\.uuid) == ["p-2"])
    }

    @Test("Filters combine across value types in one query")
    func mixedFilters() async throws {
        try await store.write([EntityWrite(values: makePurchase(uuid: "p-1").values, uuid: "p-1")], entity: "purchase")
        var cheap = makePurchase(uuid: "p-2").values
        cheap["quantity"] = .int(1)
        try await store.write([EntityWrite(values: cheap, uuid: "p-2")], entity: "purchase")

        let filters = [
            EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42")),
            EntityStore.Filter(field: "quantity", op: .greaterThan, value: .int(1)),
            EntityStore.Filter(field: "date", op: .greaterThan, value: .date(Date(timeIntervalSince1970: 500_000))),
        ]
        let records = try await store.read(entity: "purchase", any: [filters])
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Sort orders records server-side")
    func sorted() async throws {
        for (index, quantity) in [3, 1, 2].enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }

        let ascending = try await store.read(entity: "purchase", sort: [EntityStore.Sort(field: "quantity")])
        #expect(ascending.map(\.uuid) == ["p-1", "p-2", "p-0"])

        let descending = try await store.read(
            entity: "purchase",
            sort: [EntityStore.Sort(field: "quantity", ascending: false)]
        )
        #expect(descending.map(\.uuid) == ["p-0", "p-2", "p-1"])
    }

    @Test("Sorting on an unknown field fails")
    func sortUnknownField() async throws {
        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await store.read(entity: "purchase", sort: [EntityStore.Sort(field: "ghost")])
        }
    }

    @Test("OR fans out branches and unions results")
    func orBranches() async throws {
        for (index, sku) in ["sku-1", "sku-2", "sku-3"].enumerated() {
            var values = makePurchase().values
            values["product_id"] = .string(sku)
            values["quantity"] = .int(Int64(index + 1))
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }

        let branches = [
            [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-1"))],
            [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-3"))],
            [EntityStore.Filter(field: "quantity", op: .greaterThan, value: .int(2))],
        ]
        let records = try await store.read(
            entity: "purchase",
            any: branches,
            sort: [EntityStore.Sort(field: "quantity")]
        )
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("NOT IN excludes listed values server-side")
    func notIn() async throws {
        try await store.write([EntityWrite(values: makePurchase(uuid: "p-1").values, uuid: "p-1")], entity: "purchase")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write([EntityWrite(values: other, uuid: "p-2")], entity: "purchase")

        let filter = EntityStore.Filter(field: "product_id", op: .notIn, value: .strings(["sku-42"]))
        let records = try await store.read(entity: "purchase", any: [[filter]])
        #expect(records.map(\.uuid) == ["p-2"])
    }

    @Test("A half-open range keeps the lower bound and drops the upper")
    func halfOpenRange() async throws {
        for (index, seconds) in [1_000, 2_000, 3_000].enumerated() {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }
        let range =
            "date" >= .date(Date(timeIntervalSince1970: 1_500))
            && "date" < .date(Date(timeIntervalSince1970: 3_000))
        let records = try await store.query("purchase").filter(range).take(100)
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Contains over a list field conjoins and disjoins")
    func tagCombinators() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "post",
                fields: [
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00"))
                ]
            )
        )
        try await store.write([EntityWrite(values: ["tags": .strings(["swift", "ios"])], uuid: "n-1")], entity: "post")
        try await store.write(
            [EntityWrite(values: ["tags": .strings(["swift", "server"])], uuid: "n-2")], entity: "post")
        try await store.write([EntityWrite(values: ["tags": .strings(["android"])], uuid: "n-3")], entity: "post")

        let both = try await store.query("post").filter("tags" ~~ "swift" && "tags" ~~ "ios").take(100)
        #expect(both.map(\.uuid) == ["n-1"])

        let either = try await store.query("post").filter("tags" ~~ "ios" || "tags" ~~ "server").take(100)
        #expect(Set(either.map(\.uuid)) == ["n-1", "n-2"])
    }

    @Test("Numeric and date arrays round-trip and filter with contains")
    func numericArrays() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sample",
                fields: [
                    FieldDefinition(name: "codes", type: .intList, storage: .slot(.intList, "li_00")),
                    FieldDefinition(name: "scores", type: .doubleList, storage: .slot(.doubleList, "ld_00")),
                    FieldDefinition(name: "times", type: .timestampList, storage: .slot(.timestampList, "lt_00")),
                ]
            )
        )
        let t0 = Date(timeIntervalSince1970: 1_000)
        try await store.write(
            [
                EntityWrite(
                    values: ["codes": .ints([1, 2, 3]), "scores": .doubles([9.5]), "times": .dates([t0])], uuid: "s-1")
            ], entity: "sample")
        try await store.write(
            [
                EntityWrite(
                    values: ["codes": .ints([4, 5]), "scores": .doubles([1.0]), "times": .dates([])], uuid: "s-2")
            ], entity: "sample")

        let record = try #require(try await store.read(entity: "sample").first { $0.uuid == "s-1" })
        #expect(record.values["codes"] == .ints([1, 2, 3]))
        #expect(record.values["scores"] == .doubles([9.5]))
        #expect(record.values["times"] == .dates([t0]))

        let whole = try #require(try await store.read(entity: "sample").first { $0.uuid == "s-2" })
        #expect(whole.values["scores"] == .doubles([1.0]))

        let filter = EntityStore.Filter(field: "codes", op: .contains, value: .int(2))
        let matched = try await store.read(entity: "sample", any: [[filter]])
        #expect(matched.map(\.uuid) == ["s-1"])
    }

    @Test("A reference scalar round-trips")
    func exoticTypes() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "graph",
                fields: [
                    FieldDefinition(name: "parent", type: .reference, storage: .slot(.reference, "r_00"))
                ]
            )
        )
        try await store.write([EntityWrite(values: ["parent": .reference("node-9")], uuid: "g-1")], entity: "graph")

        let record = try #require(try await store.read(entity: "graph").first)
        #expect(record.values["parent"] == .reference("node-9"))
    }

    @Test("A scalar bytes field lives in its own slot")
    func bytesSlot() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "blob",
                fields: [
                    FieldDefinition(name: "digest", type: .bytes, storage: .slot(.bytes, "b_00"))
                ]
            )
        )
        let payload = Data([0xDE, 0xAD])
        try await store.write([EntityWrite(values: ["digest": .bytes(payload)], uuid: "b-1")], entity: "blob")
        let record = try #require(try await store.read(entity: "blob").first)
        #expect(record.values["digest"] == .bytes(payload))
    }

    @Test("Filtering on an unknown field fails")
    func unknownFilter() async throws {
        let filter = EntityStore.Filter(field: "ghost", op: .equals, value: .string("x"))
        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await store.read(entity: "purchase", any: [[filter]])
        }
    }

    @Test("Reading an unpublished entity fails")
    func unknownEntity() async throws {
        await #expect(throws: SchemaError.unknownEntity("ghost")) {
            try await store.read(entity: "ghost")
        }
    }

    @Test("Unique key turns writes into upserts")
    func uniqueUpsert() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "score", type: .int, storage: .slot(.int, "i_00")),
                ],
                unique: ["user_id"]
            )
        )

        let first = try await store.write(
            [EntityWrite(values: ["user_id": .string("alice"), "score": .int(1)])], entity: "profile")
        let second = try await store.write(
            [EntityWrite(values: ["user_id": .string("alice"), "score": .int(2)])], entity: "profile")
        #expect(first == second)

        let records = try await store.read(entity: "profile")
        #expect(records.count == 1)
        #expect(records.first?.values["score"] == .int(2))
    }

    @Test("List fields support server-side contains filters")
    func tags() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "post",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                ]
            )
        )
        try await store.write(
            [EntityWrite(values: ["title": .string("Intro"), "tags": .strings(["swift", "ios"])], uuid: "n-1")],
            entity: "post")
        try await store.write(
            [EntityWrite(values: ["title": .string("Server"), "tags": .strings(["vapor"])], uuid: "n-2")],
            entity: "post")

        let filter = EntityStore.Filter(field: "tags", op: .contains, value: .string("swift"))
        let records = try await store.read(entity: "post", any: [[filter]])
        #expect(records.map(\.uuid) == ["n-1"])
    }

    @Test("Aggregate views count writes into grid cells")
    func aggregation() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "tap",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                views: [AggregateView(name: "by_name", groupBy: "name")]
            )
        )

        let date = Date(timeIntervalSince1970: 36_000)
        try await store.write([EntityWrite(values: ["name": .string("open"), "date": .date(date)])], entity: "tap")
        try await store.write([EntityWrite(values: ["name": .string("open"), "date": .date(date)])], entity: "tap")

        let grids = database.records.filter { $0.recordType == "Aggregate" }
        #expect(grids.count == 1)
        #expect(grids.first?[CKRecord.countCell] as? Int64 == 2)
        #expect(grids.first?["group_key"] == "open")
    }

    @Test("Sum views accumulate values into double cells")
    func sumView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "payment",
                fields: [
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                views: [AggregateView(name: "total", sum: "amount")]
            )
        )

        let date = Date(timeIntervalSince1970: 36_000)
        try await store.write([EntityWrite(values: ["amount": .double(2.5), "date": .date(date)])], entity: "payment")
        try await store.write([EntityWrite(values: ["amount": .double(1.5), "date": .date(date)])], entity: "payment")

        let grids = database.records.filter { $0.recordType == "Aggregate" }
        #expect(grids.count == 1)
        #expect(grids.first?[CKRecord.countCell] as? Int64 == 2)
        #expect(grids.first?[CKRecord.valueCell] as? Double == 4.0)
    }
}
