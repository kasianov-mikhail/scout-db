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

    private func publishPayment(aggregates: [AggregateDefinition], required: Bool = false) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "payment",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: required),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                aggregates: aggregates
            )
        )
    }

    private func writePayments(_ amounts: [Double], product: String = "app") async throws {
        for amount in amounts {
            try await store.write(
                [
                    EntityWrite(
                        values: ["product": .string(product), "amount": .double(amount), "date": .date(noon)], uuid: nil
                    )
                ],
                entity: "payment")
        }
    }

    @Test("An upsert counts once in aggregates")
    func upsertCountsOnce() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "visit",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                aggregates: [AggregateDefinition()]
            )
        )

        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "date": .date(noon)], uuid: "v-1")], entity: "visit")
        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "date": .date(noon)], uuid: "v-1")], entity: "visit")

        #expect(try await ReadOperation(store: store, entity: "visit").records().count == 1)
        #expect(
            try await TotalOperation(store: store, entity: "visit").rows(aggregate: "by_all").map(\.value) == [1])
    }

    @Test("An upsert with a changed value rebalances a sum aggregate")
    func upsertRebalancesSumView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "meter",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                aggregates: [AggregateDefinition(measure: .sum("amount"))]
            )
        )

        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "amount": .double(10), "date": .date(noon)], uuid: "m-1")],
            entity: "meter")
        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "amount": .double(25), "date": .date(noon)], uuid: "m-1")],
            entity: "meter")

        #expect(try await ReadOperation(store: store, entity: "meter").records().count == 1)
        let totals = try await TotalOperation(store: store, entity: "meter").rows(aggregate: "sum_amount")
        #expect(totals.first?.value == 25)
    }

    @Test("A sharded aggregate spreads a hot slot over several records and reads back whole")
    func shardedView() async throws {
        try await publishPayment(
            aggregates: [
                AggregateDefinition(measure: .sum("amount"), shards: 3),
                AggregateDefinition(shards: 3),
            ]
        )
        for index in 0..<6 {
            try await store.write(
                [
                    EntityWrite(
                        values: ["product": .string("app"), "amount": .double(Double(index + 1)), "date": .date(noon)],
                        uuid: "p-\(index)")
                ], entity: "payment")
        }
        let cells = database.records.filter { $0[VectorSlot.Key.aggregate] as? String == "sum_amount" }
        #expect(cells.count > 1)
        #expect(cells.count <= 3)

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "sum_amount")
        #expect(totals.count == 1)
        #expect(totals.first?.value == 21)

        #expect(try await store.query("payment").count() == 6)

        let invalid = makeDefinition(
            entity: "e",
            fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_02"))],
            aggregates: [AggregateDefinition(shards: 1)]
        )
        #expect(throws: SchemaError.invalidDefinition(.invalidShards(aggregate: "by_all"))) { try invalid.validate() }
    }

    @Test("A min aggregate keeps the extremum an upsert lifted a record off")
    func upsertKeepsMinExtremum() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "meter",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ],
                aggregates: [AggregateDefinition(measure: .min("amount"))]
            )
        )

        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "amount": .double(2), "date": .date(noon)], uuid: "m-1")],
            entity: "meter")
        try await store.write(
            [EntityWrite(values: ["user": .string("u2"), "amount": .double(8), "date": .date(noon)], uuid: "m-2")],
            entity: "meter")
        try await store.write(
            [EntityWrite(values: ["user": .string("u1"), "amount": .double(6), "date": .date(noon)], uuid: "m-1")],
            entity: "meter")

        let totals = try await TotalOperation(store: store, entity: "meter").rows(aggregate: "min_amount")
        #expect(totals.first?.value == 2)
    }

    @Test("MIN aggregate keeps the smallest value")
    func minView() async throws {
        try await publishPayment(aggregates: [AggregateDefinition(measure: .min("amount"))])
        try await writePayments([5, 2, 8])

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "min_amount")
        #expect(totals.count == 1)
        #expect(totals.first?.value == 2)
    }

    @Test("MAX aggregate keeps the largest value")
    func maxView() async throws {
        try await publishPayment(aggregates: [AggregateDefinition(measure: .max("amount"))])
        try await writePayments([5, 2, 8])

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "max_amount")
        #expect(totals.first?.value == 8)
    }

    @Test("AVG divides a sum aggregate by the count aggregate beside it")
    func average() async throws {
        try await publishPayment(
            aggregates: [
                AggregateDefinition(measure: .sum("amount")),
                AggregateDefinition(),
            ],
            required: true
        )
        try await writePayments([2.5, 1.5])

        let total = try #require(
            try await TotalOperation(store: store, entity: "payment").rows(aggregate: "sum_amount").first)
        #expect(total.value == 4)
        #expect(try await store.query("payment").average("amount") == 2)
    }

    private func writePayment(_ amount: Double, at date: Date, uuid: String? = nil) async throws {
        try await store.write(
            [
                EntityWrite(
                    values: ["product": .string("app"), "amount": .double(amount), "date": .date(date)],
                    uuid: uuid
                )
            ],
            entity: "payment"
        )
    }

    @Test("Weeks keep a vector each, and a fold reads across them")
    func weeksFoldTogether() async throws {
        try await publishPayment(
            aggregates: [
                AggregateDefinition(date: "date"),
                AggregateDefinition(measure: .sum("amount"), date: "date"),
            ]
        )
        try await writePayment(2, at: noon)
        try await writePayment(3, at: noon.addingTimeInterval(3_600))
        try await writePayment(10, at: noon.addingTimeInterval(7 * 86_400))

        #expect(database.records.filter { $0[VectorSlot.Key.aggregate] as? String == "at_date" }.count == 2)
        #expect(try await store.query("payment").count() == 3)
        #expect(try await store.query("payment").sum("amount") == 15)
    }

    @Test("A rewrite dated by the record leaves the cell it first landed in")
    func rewriteMovesBetweenWeeks() async throws {
        try await publishPayment(
            aggregates: [
                AggregateDefinition(date: "date"),
                AggregateDefinition(measure: .sum("amount"), date: "date"),
            ]
        )
        let moved = noon.addingTimeInterval(7 * 86_400)

        try await writePayment(10, at: noon, uuid: "p-1")
        try await writePayment(10, at: moved, uuid: "p-1")

        let counted = database.records.filter { $0[VectorSlot.Key.aggregate] as? String == "at_date" }
        #expect(counted.count == 2)
        #expect(counted.first { $0[VectorSlot.Key.week] as? Date == noon.weekStart }?.cells() == 0)
        #expect(counted.first { $0[VectorSlot.Key.week] as? Date == moved.weekStart }?[cell: moved.hourOfWeek] == 1)

        #expect(try await store.query("payment").count() == 1)
        #expect(try await store.query("payment").sum("amount") == 10)
    }

    @Test("GROUP BY works over totals")
    func groupByTotals() async throws {
        try await publishPayment(aggregates: [
            AggregateDefinition(groupBy: "product", measure: .sum("amount"))
        ])
        try await writePayments([1, 2, 3], product: "app")
        try await writePayments([10], product: "bundle")

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "sum_amount_by_product")
        #expect(totals.map(\.group) == ["app", "bundle"])
        #expect(totals.map(\.value) == [6, 10])
    }

    @Test("A single-group aggregate read narrows to that group's rows")
    func aggregateOneGroup() async throws {
        try await publishPayment(aggregates: [
            AggregateDefinition(groupBy: "product", measure: .sum("amount"))
        ])
        try await writePayments([10, 5], product: "app")
        try await writePayments([2], product: "book")

        let totals = try await TotalOperation(store: store, entity: "payment").rows(
            aggregate: "sum_amount_by_product", group: "book")
        #expect(totals.map(\.group) == ["book"])
        #expect(totals.first?.value == 2)
        #expect(
            try await TotalOperation(store: store, entity: "payment").rows(
                aggregate: "sum_amount_by_product", group: "app"
            )
            .map(\.value) == [15]
        )
    }

    @Test("A aggregate with two metrics is rejected")
    func metricExclusivity() throws {
        let json = Data(#"{"sum":"amount","min":"amount"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AggregateDefinition.self, from: json)
        }
    }

    @Test("A batched write aggregates like the equivalent single writes")
    func batchAggregation() async throws {
        try await publishPayment(aggregates: [
            AggregateDefinition(groupBy: "product", measure: .sum("amount"))
        ])
        try await store.write(
            [
                EntityWrite(values: ["product": .string("app"), "amount": .double(2), "date": .date(noon)], uuid: nil),
                EntityWrite(values: ["product": .string("app"), "amount": .double(3), "date": .date(noon)], uuid: nil),
                EntityWrite(
                    values: ["product": .string("book"), "amount": .double(10), "date": .date(noon)], uuid: nil),
            ],
            entity: "payment"
        )

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "sum_amount_by_product")

        #expect(totals.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 5)
        #expect(totals.first { $0.group == "book" }?.value == 10)
    }

    @Test("A batched write folds MIN across the whole batch")
    func batchMinFold() async throws {
        try await publishPayment(aggregates: [AggregateDefinition(measure: .min("amount"))])
        try await store.write(
            [5, 2, 8].map {
                EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)], uuid: nil)
            },
            entity: "payment"
        )

        let totals = try await TotalOperation(store: store, entity: "payment").rows(aggregate: "min_amount")
        #expect(totals.count == 1)
        #expect(totals.first?.value == 2)
    }

    @Test("A batched write touches each vector once")
    func batchVectorWrites() async throws {
        try await publishPayment(aggregates: [
            AggregateDefinition(groupBy: "product", measure: .sum("amount"))
        ])
        try await store.write(
            [1, 2, 3, 4].map {
                EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)], uuid: nil)
            },
            entity: "payment"
        )

        #expect(database.records.filter { $0.recordType == "Vector" }.count == 1)
    }

    @Test("A aggregate keeps one running total per category")
    func lifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                aggregates: [AggregateDefinition(groupBy: "product", measure: .sum("amount"))]
            )
        )

        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(10)], uuid: nil)], entity: "sale")
        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(5)], uuid: nil)], entity: "sale")
        try await store.write(
            [EntityWrite(values: ["product": .string("book"), "amount": .double(2)], uuid: nil)], entity: "sale")

        let totals = try await TotalOperation(store: store, entity: "sale").rows(aggregate: "sum_amount_by_product")
        #expect(totals.first { $0.group == "app" }?.value == 15)
        #expect(totals.first { $0.group == "book" }?.value == 2)
        #expect(database.records.filter { $0.recordType == "Vector" }.count == 2)
    }

    @Test("count() reads a covering aggregate's vector instead of scanning")
    func countThroughLifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ],
                aggregates: [AggregateDefinition(groupBy: "product")]
            )
        )
        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(10)], uuid: nil)], entity: "sale")
        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(5)], uuid: nil)], entity: "sale")
        try await store.write(
            [EntityWrite(values: ["product": .string("book"), "amount": .double(2)], uuid: nil)], entity: "sale")

        #expect(try await store.query("sale").count() == 3)
        #expect(try await store.query("sale").filter("product", .equals, "app").count() == 2)
        #expect(try await store.query("sale").limit(1).count() == 1)

        let vector = try #require(
            database.records.first { $0.recordType == "Vector" && $0[VectorSlot.Key.group] as? String == "book" }
        )
        vector.reset(cellsTo: 41)
        #expect(try await store.query("sale").count() == 43)
        #expect(try await store.query("sale").filter("product", .equals, "book").count() == 41)

        for uncovered in [
            store.query("sale").filter("amount" > 4),
            store.query("sale").filter("product", .notEquals, "app"),
            store.query("sale").filter("product", .equals, "app").filter("amount" > 1),
        ] {
            await #expect(throws: SchemaError.self) { try await uncovered.count() }
        }
    }

    @Test("count() honors IN lists and OR groups through the aggregate's vector")
    func countThroughKeySets() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ticket",
                fields: [
                    FieldDefinition(name: "kind", type: .string, storage: .slot(.string, "s_02"), required: true),
                    FieldDefinition(name: "price", type: .double, storage: .slot(.double, "d_00")),
                ],
                aggregates: [
                    AggregateDefinition(groupBy: "kind"),
                    AggregateDefinition(groupBy: "kind", measure: .sum("price")),
                ]
            )
        )
        try await store.write(
            [EntityWrite(values: ["kind": .string("a"), "price": .double(10)], uuid: nil)], entity: "ticket")
        try await store.write(
            [EntityWrite(values: ["kind": .string("a"), "price": .double(5)], uuid: nil)], entity: "ticket")
        try await store.write(
            [EntityWrite(values: ["kind": .string("b"), "price": .double(2)], uuid: nil)], entity: "ticket")
        try await store.write(
            [EntityWrite(values: ["kind": .string("c"), "price": .double(4)], uuid: nil)], entity: "ticket")

        let counted = try #require(
            database.records.first {
                $0[VectorSlot.Key.aggregate] as? String == "by_kind"
                    && $0[VectorSlot.Key.group] as? String == "b"
            }
        )
        counted.reset(cellsTo: 41)

        let summed = try #require(
            database.records.first {
                $0[VectorSlot.Key.aggregate] as? String == "sum_price_by_kind"
                    && $0[VectorSlot.Key.group] as? String == "b"
            }
        )
        summed.reset(cellsTo: 100)

        #expect(try await store.query("ticket").filter("kind", .in, .strings(["b", "c"])).count() == 42)
        #expect(
            try await store.query("ticket")
                .filter("kind" == "a" || "kind" == "b").count() == 43
        )
        #expect(
            try await store.query("ticket")
                .filter("kind" == "b" || "kind" == "b").count() == 41
        )
        #expect(try await store.query("ticket").filter("kind", .in, .strings(["a", "b"])).sum("price") == 115)

        await #expect(throws: SchemaError.self) {
            try await store.query("ticket").filter("kind" == "a" || "price" == .double(2)).count()
        }
    }

    @Test("A threshold on a bounded integer field names the vector keys it covers")
    func countThroughNamedDomain() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "crate",
                fields: [
                    FieldDefinition(
                        name: "units",
                        type: .int,
                        storage: .slot(.int, "i_01"),
                        required: true,
                        min: 1,
                        max: 20
                    ),
                    FieldDefinition(name: "weight", type: .int, storage: .slot(.int, "i_02"), required: true),
                ],
                aggregates: [AggregateDefinition(groupBy: "units")]
            )
        )
        for units: Int64 in [1, 5, 12, 16, 20] {
            try await store.write(
                [EntityWrite(values: ["units": .int(units), "weight": .int(units * 100)], uuid: nil)], entity: "crate")
        }

        let vector = try #require(
            database.records.first { $0.recordType == "Vector" && $0[VectorSlot.Key.group] as? String == "i16" }
        )
        vector.reset(cellsTo: 41)

        #expect(try await store.query("crate").filter("units", .greaterThan, .int(15)).count() == 42)
        #expect(try await store.query("crate").filter("units", .greaterThanOrEquals, .int(16)).count() == 42)
        #expect(try await store.query("crate").filter("units", .lessThan, .int(16)).count() == 3)
        #expect(try await store.query("crate").filter("units", .lessThanOrEquals, .int(12)).count() == 3)
        #expect(try await store.query("crate").filter("units", .greaterThanOrEquals, .int(21)).count() == 0)

        await #expect(throws: SchemaError.self) {
            try await store.query("crate").filter("weight", .greaterThan, .int(1_500)).count()
        }
    }

    @Test("A date range falls outside what a vector answers, and is refused rather than scanned")
    func countThroughDateRangeScans() async throws {
        try await publishPayment(aggregates: [AggregateDefinition(groupBy: "product")])
        try await writePayments([1, 2], product: "app")
        try await store.write(
            [
                EntityWrite(
                    values: [
                        "product": .string("app"), "amount": .double(9), "date": .date(noon.addingTimeInterval(86_400)),
                    ],
                    uuid: nil
                )
            ], entity: "payment")

        let vector = try #require(database.records.first { $0.recordType == "Vector" })
        vector.reset(cellsTo: 41)

        #expect(try await store.query("payment").count() == 41)

        await #expect(
            throws: SchemaError.unsupportedQuery(.noAggregate(entity: "payment", grouping: nil, folding: nil))
        ) {
            try await store.query("payment")
                .filter("date", .greaterThanOrEquals, .date(noon.addingTimeInterval(3_600)))
                .count()
        }
    }

    private func publishLedger(required: Bool = true) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ledger",
                fields: [
                    FieldDefinition(
                        name: "product",
                        type: .string,
                        storage: .slot(.string, "s_02"),
                        required: required
                    ),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: required),
                ],
                aggregates: [
                    AggregateDefinition(groupBy: "product"),
                    AggregateDefinition(groupBy: "product", measure: .sum("amount")),
                ]
            )
        )
        for (product, amount) in [("app", 10.0), ("app", 6.0), ("book", 4.0)] {
            try await store.write(
                [EntityWrite(values: ["product": .string(product), "amount": .double(amount)], uuid: nil)],
                entity: "ledger")
        }
    }

    private func tamperBookSlots() throws {
        let counted = try #require(
            database.records.first {
                $0[VectorSlot.Key.aggregate] as? String == "by_product" && $0[VectorSlot.Key.group] as? String == "book"
            }
        )
        counted.reset(cellsTo: 3)

        let summed = try #require(
            database.records.first {
                $0[VectorSlot.Key.aggregate] as? String == "sum_amount_by_product"
                    && $0[VectorSlot.Key.group] as? String == "book"
            }
        )
        summed.reset(cellsTo: 40)
    }

    @Test("sum() and average() read a covering aggregate's vector, while min and max find none")
    func foldThroughLifetimeView() async throws {
        try await publishLedger()
        #expect(try await store.query("ledger").sum("amount") == 20)
        #expect(try await store.query("ledger").average("amount") == 20.0 / 3)

        try tamperBookSlots()
        #expect(try await store.query("ledger").sum("amount") == 56)
        #expect(try await store.query("ledger").average("amount") == 56.0 / 5)
        #expect(try await store.query("ledger").filter("product", .equals, "book").sum("amount") == 40)
        #expect(try await store.query("ledger").filter("product", .equals, "book").average("amount") == 40.0 / 3)
        #expect(try await store.query("ledger").filter("product", .equals, "app").sum("amount") == 16)

        let uncovered = SchemaError.unsupportedQuery(
            .noAggregate(entity: "ledger", grouping: nil, folding: "amount")
        )
        await #expect(throws: uncovered) { try await store.query("ledger").min("amount") }
        await #expect(throws: uncovered) { try await store.query("ledger").max("amount") }
    }

    @Test("An extremum reads its aggregate's vector instead of scanning")
    func extremumThroughView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "reading",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02"), required: true),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: true),
                ],
                aggregates: [
                    AggregateDefinition(groupBy: "product", measure: .max("amount")),
                    AggregateDefinition(groupBy: "product", measure: .min("amount")),
                ]
            )
        )
        for (product, amount) in [("app", 10.0), ("app", 6.0), ("book", 4.0)] {
            try await store.write(
                [EntityWrite(values: ["product": .string(product), "amount": .double(amount)], uuid: nil)],
                entity: "reading")
        }

        for aggregate in ["max_amount_by_product", "min_amount_by_product"] {
            let vector = try #require(
                database.records.first {
                    $0.recordType == "Vector" && $0[VectorSlot.Key.aggregate] as? String == aggregate
                        && $0[VectorSlot.Key.group] as? String == "book"
                }
            )
            vector.reset(cellsTo: aggregate == "max_amount_by_product" ? 41 : 1)
        }

        #expect(try await store.query("reading").max("amount") == 41)
        #expect(try await store.query("reading").filter("product", .equals, "book").max("amount") == 41)
        let peaks = try await store.query("reading").totals("amount", metric: .max, group: "product")
        #expect(peaks.map(\.group) == ["app", "book"])
        #expect(peaks.map(\.value) == [10, 41])

        #expect(try await store.query("reading").min("amount") == 1)
    }

    @Test("Grouped totals read the grouping aggregate's vector")
    func groupedFoldThroughLifetimeView() async throws {
        try await publishLedger()
        try tamperBookSlots()

        let totals = try await store.query("ledger").totals("amount", metric: .sum, group: "product")
        #expect(totals.map(\.group) == ["app", "book"])
        #expect(totals.map(\.value) == [16, 40])

        let averages = try await store.query("ledger").totals("amount", metric: .average, group: "product")
        #expect(averages.map(\.value) == [8, 40.0 / 3])
    }

    @Test("A fold that divides by the vector's row count is refused when the field may be absent")
    func foldFallsBackForOptionalField() async throws {
        try await publishLedger(required: false)
        try tamperBookSlots()

        #expect(try await store.query("ledger").sum("amount") == 56)

        await #expect(throws: SchemaError.unsupportedQuery(.averageOfOptional("amount"))) {
            try await store.query("ledger").average("amount")
        }
    }

    @Test("A fold over one group asks the server for that group's rows only")
    func groupScopedVectorQuery() async throws {
        try await publishLedger()
        let watched = VectorQueries(backing: database)
        let reader = EntityStore(database: watched, registry: registry)
        #expect(database.records.filter { $0.recordType == "Vector" }.count == 4)

        let scoped = try await reader.query("ledger").filter("product", .equals, "book").sum("amount")
        #expect(scoped == 4)
        let grouped = try #require(watched.vectors.last)
        #expect(grouped.query.predicate.predicateFormat.contains("s_02 == \"book\""))
        #expect(grouped.matched == 1)

        let whole = try await reader.query("ledger").sum("amount")
        #expect(whole == 20)
        let ungrouped = try #require(watched.vectors.last)
        #expect(ungrouped.query.predicate.predicateFormat.contains("group_key") == false)
        #expect(ungrouped.matched == 2)
    }

    @Test("A fold with no covering aggregate names what is missing")
    func foldWithoutCoveringView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "fee",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02"), required: true),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: true),
                    FieldDefinition(name: "tax", type: .double, storage: .slot(.double, "d_01"), required: true),
                ],
                aggregates: [AggregateDefinition(groupBy: "product", measure: .sum("amount"))]
            )
        )
        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(10), "tax": .double(1)], uuid: nil)],
            entity: "fee")
        try await store.write(
            [EntityWrite(values: ["product": .string("book"), "amount": .double(4), "tax": .double(2)], uuid: nil)],
            entity: "fee")

        await #expect(
            throws: SchemaError.unsupportedQuery(.noAggregate(entity: "fee", grouping: nil, folding: "tax"))
        ) {
            try await store.query("fee").sum("tax")
        }
        await #expect(throws: SchemaError.self) {
            try await store.query("fee").filter("product", .notEquals, "app").sum("amount")
        }
    }
}

private final class VectorQueries: CloudDatabase, @unchecked Sendable {
    private let backing: InMemoryDatabase
    private let lock = NSLock()
    private var log: [(query: CKQuery, matched: Int)] = []

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    var vectors: [(query: CKQuery, matched: Int)] {
        lock.withLock { log.filter { $0.query.recordType == VectorSlot.recordType } }
    }

    func records(matching query: CKQuery, resultsLimit: Int) async throws -> QueryPage {
        let response = try await backing.records(matching: query, resultsLimit: resultsLimit)
        lock.withLock { log.append((query, response.matchResults.count)) }
        return response
    }

    func records(continuingMatchFrom cursor: QueryCursor, resultsLimit: Int) async throws -> QueryPage {
        try await backing.records(continuingMatchFrom: cursor, resultsLimit: resultsLimit)
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
