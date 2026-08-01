//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Aggregates")
struct AggregatesTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry
    let noon = Date(timeIntervalSince1970: 36_000)

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
    }

    private func publishPayment(views: [AggregateView]) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "payment",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                views: views
            )
        )
    }

    private func writePayments(_ amounts: [Double], product: String = "app") async throws {
        for amount in amounts {
            try await store.write(
                ["product": .string(product), "amount": .double(amount), "date": .date(noon)],
                entity: "payment"
            )
        }
    }

    @Test("A grid slot named before separators were escaped is still adopted")
    func legacyGridSlotAdoption() async throws {
        try await publishPayment(views: [AggregateView(name: "by_product", groupBy: "product")])

        let group = "a|b"
        let period = GridSlot.date
        let legacyKey = "payment|by_product|\(group)|\(period.millisecondsSince1970)"
        let legacyName = "grid-" + SHA256.hash(data: Data(legacyKey.utf8)).hexString
        #expect(
            legacyName != "grid-"
                + contentDigest(of: ["payment", "by_product", group, "\(period.millisecondsSince1970)"])
        )

        let legacy = CKRecord(recordType: "Aggregate", recordID: CKRecord.ID(recordName: legacyName))
        legacy["entity"] = "payment"
        legacy["view"] = "by_product"
        legacy["group_key"] = group
        legacy["date"] = period
        legacy["c_00"] = Int64(5)
        try await database.write(records: [legacy])

        try await writePayments([1], product: group)

        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 1)
        #expect(try await AggregateQuery(store, entity: "payment", view: "by_product").totals().map(\.count) == [6])
    }

    @Test("A unique-key upsert counts once in aggregate views")
    func upsertCountsOnce() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "visit",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                unique: ["user"],
                views: [AggregateView(name: "by_all")]
            )
        )

        try await store.write(["user": .string("u1"), "date": .date(noon)], entity: "visit")
        try await store.write(["user": .string("u1"), "date": .date(noon)], entity: "visit")

        #expect(try await store.read(entity: "visit").count == 1)
        #expect(try await AggregateQuery(store, entity: "visit", view: "by_all").totals().map(\.count) == [1])
    }

    @Test("A unique-key upsert with a changed value rebalances a sum view")
    func upsertRebalancesSumView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "meter",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                unique: ["user"],
                views: [AggregateView(name: "revenue", sum: "amount")]
            )
        )

        try await store.write(["user": .string("u1"), "amount": .double(10), "date": .date(noon)], entity: "meter")
        try await store.write(["user": .string("u1"), "amount": .double(25), "date": .date(noon)], entity: "meter")

        #expect(try await store.read(entity: "meter").count == 1)
        let totals = try await AggregateQuery(store, entity: "meter", view: "revenue").totals()
        #expect(totals.first?.count == 1)
        #expect(totals.first?.value == 25)
    }

    @Test("A sharded view spreads a hot slot over several records and reads back whole")
    func shardedView() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount", shards: 3)])
        for index in 0..<6 {
            try await store.write(
                ["product": .string("app"), "amount": .double(Double(index + 1)), "date": .date(noon)],
                entity: "payment",
                uuid: "p-\(index)"
            )
        }
        let shards = Set((0..<6).map { GridAggregator.shard(of: "p-\($0)", among: 3) })
        #expect(shards.count > 1)
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == shards.count)

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue").totals()
        #expect(totals.count == 1)
        #expect(totals.first?.count == 6)
        #expect(totals.first?.value == 21)

        try await store.delete(entity: "payment", uuid: "p-3")
        #expect(try await AggregateQuery(store, entity: "payment", view: "revenue").totals().map(\.count) == [5])
        #expect(try await store.query("payment").count() == 5)

        let invalid = makeDefinition(
            entity: "e",
            fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))],
            views: [AggregateView(name: "x", shards: 1)]
        )
        #expect(throws: SchemaError.self) { try invalid.validate() }
    }

    @Test("Deleting a record reverses its aggregate contribution")
    func deleteReversesAggregate() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await store.write(
            ["product": .string("app"), "amount": .double(2), "date": .date(noon)],
            entity: "payment",
            uuid: "p1"
        )
        try await store.write(
            ["product": .string("app"), "amount": .double(3), "date": .date(noon)],
            entity: "payment",
            uuid: "p2"
        )

        try await store.delete(entity: "payment", uuid: "p1")

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue").totals()
        #expect(totals.first?.count == 1)
        #expect(totals.first?.value == 3)
    }

    @Test("Updating a record rebalances a sum view")
    func updateRebalancesAggregate() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await store.write(
            ["product": .string("app"), "amount": .double(2), "date": .date(noon)],
            entity: "payment",
            uuid: "p1"
        )

        try await store.update(entity: "payment", uuid: "p1") { $0.values["amount"] = .double(10) }

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue").totals()
        #expect(totals.first?.count == 1)
        #expect(totals.first?.value == 10)
    }

    @Test("Deleting a record decrements the count of a min view even though the extremum stays")
    func deleteHoldsMinExtremum() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await store.write(
            ["product": .string("app"), "amount": .double(2), "date": .date(noon)],
            entity: "payment",
            uuid: "p1"
        )
        try await store.write(
            ["product": .string("app"), "amount": .double(8), "date": .date(noon)],
            entity: "payment",
            uuid: "p2"
        )

        try await store.delete(entity: "payment", uuid: "p1")

        let totals = try await AggregateQuery(store, entity: "payment", view: "low").totals()
        #expect(totals.first?.count == 1)
        #expect(totals.first?.value == 2)
    }

    @Test("A min view keeps the extremum an update lifted a record off")
    func updateKeepsMinExtremum() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await store.write(
            ["product": .string("app"), "amount": .double(2), "date": .date(noon)],
            entity: "payment",
            uuid: "p1"
        )
        try await store.write(
            ["product": .string("app"), "amount": .double(8), "date": .date(noon)],
            entity: "payment",
            uuid: "p2"
        )

        try await store.update(entity: "payment", uuid: "p1") { $0.values["amount"] = .double(6) }

        let totals = try await AggregateQuery(store, entity: "payment", view: "low").totals()
        #expect(totals.first?.count == 2)
        #expect(totals.first?.value == 2)
    }

    @Test("MIN view keeps the smallest value")
    func minView() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await writePayments([5, 2, 8])

        let totals = try await AggregateQuery(store, entity: "payment", view: "low").totals()
        #expect(totals.count == 1)
        #expect(totals.first?.count == 3)
        #expect(totals.first?.value == 2)
    }

    @Test("MAX view keeps the largest value")
    func maxView() async throws {
        try await publishPayment(views: [AggregateView(name: "high", max: "amount")])
        try await writePayments([5, 2, 8])

        let totals = try await AggregateQuery(store, entity: "payment", view: "high").totals()
        #expect(totals.first?.value == 8)
    }

    @Test("AVG derives from a sum view")
    func average() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await writePayments([2.5, 1.5])

        let total = try #require(try await AggregateQuery(store, entity: "payment", view: "revenue").totals().first)
        #expect(total.value == 4)
        #expect(total.average == 2)
    }

    @Test("GROUP BY works over totals")
    func groupByTotals() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", sum: "amount")])
        try await writePayments([1, 2, 3], product: "app")
        try await writePayments([10], product: "bundle")

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue").totals()
        #expect(totals.map(\.group) == ["app", "bundle"])
        #expect(totals.map(\.count) == [3, 1])
        #expect(totals.first?.value == 6)
    }

    @Test("A single-group aggregate read narrows to that group's rows")
    func aggregateOneGroup() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", sum: "amount")])
        try await writePayments([10, 5], product: "app")
        try await writePayments([2], product: "book")

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue", group: "book").totals()
        #expect(totals.map(\.group) == ["book"])
        #expect(totals.first?.value == 2)
        #expect(
            try await AggregateQuery(store, entity: "payment", view: "revenue", group: "app").totals().map(\.value) == [15]
        )
    }

    @Test("A view with two metrics is rejected")
    func metricExclusivity() async throws {
        let definition = makeDefinition(
            entity: "payment",
            fields: [
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ],
            views: [AggregateView(name: "broken", sum: "amount", min: "amount")]
        )
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("A batched write aggregates like the equivalent single writes")
    func batchAggregation() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", sum: "amount")])
        try await store.write(
            [
                EntityWrite(values: ["product": .string("app"), "amount": .double(2), "date": .date(noon)]),
                EntityWrite(values: ["product": .string("app"), "amount": .double(3), "date": .date(noon)]),
                EntityWrite(values: ["product": .string("book"), "amount": .double(10), "date": .date(noon)]),
            ],
            entity: "payment"
        )

        let totals = try await AggregateQuery(store, entity: "payment", view: "revenue").totals()

        #expect(totals.count == 2)
        #expect(totals.first { $0.group == "app" }?.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 5)
        #expect(totals.first { $0.group == "book" }?.value == 10)
    }

    @Test("A batched write folds MIN across the whole batch")
    func batchMinFold() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await store.write(
            [5, 2, 8].map {
                EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)])
            },
            entity: "payment"
        )

        let totals = try await AggregateQuery(store, entity: "payment", view: "low").totals()
        #expect(totals.count == 1)
        #expect(totals.first?.count == 3)
        #expect(totals.first?.value == 2)
    }

    @Test("A batched write touches each grid record once")
    func batchGridWrites() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", sum: "amount")])
        try await store.write(
            [1, 2, 3, 4].map {
                EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)])
            },
            entity: "payment"
        )

        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 1)
    }

    @Test("A view keeps one running total per category")
    func lifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                views: [AggregateView(name: "by_product", groupBy: "product", sum: "amount")]
            )
        )

        let first = try await store.write(["product": .string("app"), "amount": .double(10)], entity: "sale")
        try await store.write(["product": .string("app"), "amount": .double(5)], entity: "sale")
        try await store.write(["product": .string("book"), "amount": .double(2)], entity: "sale")

        var totals = try await AggregateQuery(store, entity: "sale", view: "by_product").totals()
        #expect(totals.first { $0.group == "app" }?.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 15)
        #expect(totals.first { $0.group == "book" }?.value == 2)
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 2)

        try await store.delete(entity: "sale", uuid: first)
        totals = try await AggregateQuery(store, entity: "sale", view: "by_product").totals()
        #expect(totals.first { $0.group == "app" }?.count == 1)
        #expect(totals.first { $0.group == "app" }?.value == 5)
    }

    @Test("count() reads a covering view's grid instead of scanning")
    func countThroughLifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                views: [AggregateView(name: "by_product", groupBy: "product")]
            )
        )
        try await store.write(["product": .string("app"), "amount": .double(10)], entity: "sale")
        try await store.write(["product": .string("app"), "amount": .double(5)], entity: "sale")
        try await store.write(["product": .string("book"), "amount": .double(2)], entity: "sale")

        #expect(try await store.query("sale").count() == 3)
        #expect(try await store.query("sale").filter("product", .equals, "app").count() == 2)
        #expect(try await store.query("sale").limit(1).count() == 1)

        let grid = try #require(
            database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" }
        )
        grid["c_00"] = Int64(41)
        #expect(try await store.query("sale").count() == 43)
        #expect(try await store.query("sale").filter("product", .equals, "book").count() == 41)

        #expect(try await store.query("sale").filter("amount" > 4).count() == 2)
        #expect(try await store.query("sale").exclude("product", .equals, "app").count() == 1)
        #expect(try await store.query("sale").filter("product", .equals, "app").filter("amount" > 1).count() == 2)
    }

    @Test("count() honors IN lists and OR groups through the view's grid")
    func countThroughKeySets() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ticket",
                fields: [
                    FieldDefinition(name: "kind", type: .string, storage: .slot(.string, "s_00"), required: true),
                    FieldDefinition(name: "price", type: .double, storage: .slot(.double, "d_00")),
                ],
                views: [AggregateView(name: "by_kind", groupBy: "kind", sum: "price")]
            )
        )
        try await store.write(["kind": .string("a"), "price": .double(10)], entity: "ticket")
        try await store.write(["kind": .string("a"), "price": .double(5)], entity: "ticket")
        try await store.write(["kind": .string("b"), "price": .double(2)], entity: "ticket")
        try await store.write(["kind": .string("c"), "price": .double(4)], entity: "ticket")

        let grid = try #require(
            database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "b" }
        )
        grid["c_00"] = Int64(41)
        grid["f_00"] = Double(100)

        #expect(try await store.query("ticket").filter("kind", .in, .strings(["b", "c"])).count() == 42)
        #expect(
            try await store.query("ticket")
                .filter("kind" == "a" || "kind" == "b").count() == 43
        )
        #expect(
            try await store.query("ticket")
                .filter("kind" == "b" || "kind" == "b").count() == 41
        )
        #expect(
            try await FoldQuery(
                store: store,
                entity: "ticket",
                branches: [[EntityStore.Filter(field: "kind", op: .in, value: .strings(["b", "c"]))]]
            )
            .counts(group: "kind")
                == ["b": 41, "c": 1]
        )
        #expect(try await store.query("ticket").filter("kind", .in, .strings(["a", "b"])).sum("price") == 115)

        #expect(
            try await store.query("ticket")
                .filter("kind" == "a" || "price" == .double(2)).count() == 3
        )
    }

    @Test("A threshold on a bounded integer field names the grid keys it covers")
    func countThroughNamedDomain() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "crate",
                fields: [
                    FieldDefinition(
                        name: "units",
                        type: .int,
                        storage: .slot(.int, "i_00"),
                        required: true,
                        min: 1,
                        max: 20
                    ),
                    FieldDefinition(name: "weight", type: .int, storage: .slot(.int, "i_01"), required: true),
                ],
                views: [AggregateView(name: "by_units", groupBy: "units")]
            )
        )
        for units: Int64 in [1, 5, 12, 16, 20] {
            try await store.write(["units": .int(units), "weight": .int(units * 100)], entity: "crate")
        }

        let grid = try #require(
            database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "i16" }
        )
        grid["c_00"] = Int64(41)

        #expect(try await store.query("crate").filter("units", .greaterThan, .int(15)).count() == 42)
        #expect(try await store.query("crate").filter("units", .greaterThanOrEquals, .int(16)).count() == 42)
        #expect(try await store.query("crate").filter("units", .lessThan, .int(16)).count() == 3)
        #expect(try await store.query("crate").filter("units", .lessThanOrEquals, .int(12)).count() == 3)
        #expect(try await store.query("crate").filter("units", .greaterThanOrEquals, .int(21)).count() == 0)

        #expect(try await store.query("crate").filter("weight", .greaterThan, .int(1_500)).count() == 2)
    }

    @Test("A date range falls outside what the grid answers and scans")
    func countThroughDateRangeScans() async throws {
        try await publishPayment(views: [AggregateView(name: "by_product", groupBy: "product")])
        try await writePayments([1, 2], product: "app")
        try await store.write(
            ["product": .string("app"), "amount": .double(9), "date": .date(noon.addingTimeInterval(86_400))],
            entity: "payment"
        )

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" })
        grid["c_00"] = Int64(41)

        #expect(try await store.query("payment").count() == 41)
        #expect(
            try await store.query("payment").filter("date", .greaterThanOrEquals, .date(noon.addingTimeInterval(3_600)))
                .count() == 1
        )
    }

    private func publishLedger(required: Bool = true) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ledger",
                fields: [
                    FieldDefinition(
                        name: "product",
                        type: .string,
                        storage: .slot(.string, "s_00"),
                        required: required
                    ),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: required),
                ],
                views: [AggregateView(name: "by_product", groupBy: "product", sum: "amount")]
            )
        )
        for (product, amount) in [("app", 10.0), ("app", 6.0), ("book", 4.0)] {
            try await store.write(["product": .string(product), "amount": .double(amount)], entity: "ledger")
        }
    }

    private func tamperedBookSlot() throws -> CKRecord {
        let grid = try #require(
            database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" }
        )
        grid["c_00"] = Int64(3)
        grid["f_00"] = 40.0
        return grid
    }

    @Test("sum() and average() read a covering view's grid, while min and max still scan")
    func foldThroughLifetimeView() async throws {
        try await publishLedger()
        #expect(try await store.query("ledger").sum("amount") == 20)
        #expect(try await store.query("ledger").average("amount") == 20.0 / 3)

        _ = try tamperedBookSlot()
        #expect(try await store.query("ledger").sum("amount") == 56)
        #expect(try await store.query("ledger").average("amount") == 56.0 / 5)
        #expect(try await store.query("ledger").filter("product", .equals, "book").sum("amount") == 40)
        #expect(try await store.query("ledger").filter("product", .equals, "book").average("amount") == 40.0 / 3)
        #expect(try await store.query("ledger").filter("product", .equals, "app").sum("amount") == 16)

        #expect(try await store.query("ledger").min("amount") == 4)
        #expect(try await store.query("ledger").max("amount") == 10)
    }

    @Test("An extremum reads its view's grid instead of scanning")
    func extremumThroughView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "reading",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"), required: true),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: true),
                ],
                views: [
                    AggregateView(name: "peak", groupBy: "product", max: "amount"),
                    AggregateView(name: "trough", groupBy: "product", min: "amount"),
                ]
            )
        )
        for (product, amount) in [("app", 10.0), ("app", 6.0), ("book", 4.0)] {
            try await store.write(["product": .string(product), "amount": .double(amount)], entity: "reading")
        }

        for view in ["peak", "trough"] {
            let grid = try #require(
                database.records.first {
                    $0.recordType == "Aggregate" && $0["view"] as? String == view
                        && $0["group_key"] as? String == "book"
                }
            )
            grid["f_00"] = view == "peak" ? 41.0 : 1.0
        }

        #expect(try await store.query("reading").max("amount") == 41)
        #expect(try await store.query("reading").filter("product", .equals, "book").max("amount") == 41)
        #expect(try await store.query("reading").max("amount", by: "product") == ["app": 10, "book": 41])

        #expect(try await store.query("reading").min("amount") == 1)
    }

    @Test("Grouped folds and count(by:) read the grouping view's grid")
    func groupedFoldThroughLifetimeView() async throws {
        try await publishLedger()
        _ = try tamperedBookSlot()

        #expect(try await store.query("ledger").sum("amount", by: "product") == ["app": 16, "book": 40])
        #expect(try await store.query("ledger").count(by: "product") == ["app": 2, "book": 3])
        #expect(try await store.query("ledger").average("amount", by: "product") == ["app": 8, "book": 40.0 / 3])
        #expect(try await store.query("ledger").min("amount", by: "product") == ["app": 6, "book": 4])
    }

    @Test("A fold that divides by the grid's row count scans when the field may be absent")
    func foldFallsBackForOptionalField() async throws {
        try await publishLedger(required: false)
        _ = try tamperedBookSlot()

        #expect(try await store.query("ledger").sum("amount") == 56)
        #expect(try await store.query("ledger").average("amount") == 20.0 / 3)
        #expect(try await store.query("ledger").count(by: "product") == ["app": 2, "book": 1])
        #expect(try await store.query("ledger").sum("amount", by: "product") == ["app": 16, "book": 4])
    }

    @Test("A fold over one group asks the server for that group's rows only")
    func groupScopedGridQuery() async throws {
        try await publishLedger()
        let watched = GridQueries(backing: database)
        let reader = EntityStore(database: watched, registry: registry)
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 2)

        let scoped = try await reader.query("ledger").filter("product", .equals, "book").sum("amount")
        #expect(scoped == 4)
        let grouped = try #require(watched.grid.last)
        #expect(grouped.query.predicate.predicateFormat.contains("group_key == \"book\""))
        #expect(grouped.matched == 1)

        let whole = try await reader.query("ledger").sum("amount")
        #expect(whole == 20)
        let ungrouped = try #require(watched.grid.last)
        #expect(ungrouped.query.predicate.predicateFormat.contains("group_key") == false)
        #expect(ungrouped.matched == 2)
    }

    @Test("A grid read projects the cells it folds, and nothing more")
    func gridReadProjection() async throws {
        try await publishLedger()
        let watched = GridQueries(backing: database)
        let reader = EntityStore(database: watched, registry: registry)

        _ = try await reader.query("ledger").count()
        var keys = try #require(watched.grid.last?.keys)
        #expect(keys.contains(CKRecord.countCell))
        #expect(keys.contains { $0.hasPrefix("f_") } == false)

        _ = try await reader.query("ledger").sum("amount")
        keys = try #require(watched.grid.last?.keys)
        #expect(keys.contains(CKRecord.valueCell))

        _ = try await AggregateQuery(reader, entity: "ledger", view: "by_product").totals()
        keys = try #require(watched.grid.last?.keys)
        #expect(Set(keys).isSuperset(of: ["group_key", CKRecord.countCell, CKRecord.valueCell]))
    }

    @Test("A fold with no covering view scans")
    func foldWithoutCoveringView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "fee",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"), required: true),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: true),
                    FieldDefinition(name: "tax", type: .double, storage: .slot(.double, "d_01"), required: true),
                ],
                views: [AggregateView(name: "by_product", groupBy: "product", sum: "amount")]
            )
        )
        try await store.write(["product": .string("app"), "amount": .double(10), "tax": .double(1)], entity: "fee")
        try await store.write(["product": .string("book"), "amount": .double(4), "tax": .double(2)], entity: "fee")

        let grid = try #require(
            database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" }
        )
        grid["c_00"] = Int64(3)
        grid["f_00"] = 40.0

        #expect(try await store.query("fee").sum("tax") == 3)
        #expect(try await store.query("fee").count(by: "amount") == ["d10.0": 1, "d4.0": 1])
        #expect(try await store.query("fee").exclude("product", .equals, "app").sum("amount") == 4)
    }
}

private final class GridQueries: CloudDatabase, @unchecked Sendable {
    private let backing: InMemoryDatabase
    private let lock = NSLock()
    private var log: [(query: CKQuery, keys: [CKRecord.FieldKey]?, matched: Int)] = []

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    var grid: [(query: CKQuery, keys: [CKRecord.FieldKey]?, matched: Int)] {
        lock.withLock { log.filter { $0.query.recordType == GridSlot.recordType } }
    }

    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws
        -> QueryPage
    {
        let response = try await backing.records(matching: query, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        lock.withLock { log.append((query, desiredKeys, response.matchResults.count)) }
        return response
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int)
        async throws -> QueryPage
    {
        try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
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

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await backing.fetchRecord(id: id)
    }

    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try await backing.fetchRecords(ids: ids)
    }
}
