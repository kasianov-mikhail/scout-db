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

    private func publishPayment(views: [AggregateView]) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "payment",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: views))
    }

    private func writePayments(_ amounts: [Double], product: String = "app") async throws {
        for amount in amounts {
            try await store.write(["product": .string(product), "amount": .double(amount), "date": .date(noon)], entity: "payment")
        }
    }

    @Test("A unique-key upsert counts once in aggregate views")
    func upsertCountsOnce() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "visit",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", unique: ["user"], views: [AggregateView(name: "daily", bucket: .day)]))

        // Same unique key twice: the second write upserts the same record, so the grid
        // must count one occurrence, not two.
        try await store.write(["user": .string("u1"), "date": .date(noon)], entity: "visit")
        try await store.write(["user": .string("u1"), "date": .date(noon)], entity: "visit")

        #expect(try await store.read(entity: "visit").count == 1)
        #expect(try await store.totals(entity: "visit", view: "daily").map(\.count) == [1])
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
                ], envelopeDate: "date", unique: ["user"], views: [AggregateView(name: "revenue", sum: "amount")]))

        // Same unique key twice with a changed amount: the second write upserts the
        // one record, so the sum must follow the latest value — not stay at the
        // first, not accumulate both.
        try await store.write(["user": .string("u1"), "amount": .double(10), "date": .date(noon)], entity: "meter")
        try await store.write(["user": .string("u1"), "amount": .double(25), "date": .date(noon)], entity: "meter")

        #expect(try await store.read(entity: "meter").count == 1)
        let rows = try await store.aggregate(entity: "meter", view: "revenue")
        #expect(rows.first?.count == 1)
        #expect(rows.first?.value == 25)
    }

    @Test("Deleting a record reverses its aggregate contribution")
    func deleteReversesAggregate() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await store.write(["product": .string("app"), "amount": .double(2), "date": .date(noon)], entity: "payment", uuid: "p1")
        try await store.write(["product": .string("app"), "amount": .double(3), "date": .date(noon)], entity: "payment", uuid: "p2")

        try await store.delete(entity: "payment", uuid: "p1")

        let rows = try await store.aggregate(entity: "payment", view: "revenue")
        #expect(rows.first?.count == 1)
        #expect(rows.first?.value == 3)
    }

    @Test("Updating a record rebalances a sum view")
    func updateRebalancesAggregate() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await store.write(["product": .string("app"), "amount": .double(2), "date": .date(noon)], entity: "payment", uuid: "p1")

        try await store.update(entity: "payment", uuid: "p1") { $0.values["amount"] = .double(10) }

        let rows = try await store.aggregate(entity: "payment", view: "revenue")
        #expect(rows.first?.count == 1)
        #expect(rows.first?.value == 10)
    }

    @Test("Deleting a record decrements the count of a min view even though the extremum stays")
    func deleteHoldsMinExtremum() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await store.write(["product": .string("app"), "amount": .double(2), "date": .date(noon)], entity: "payment", uuid: "p1")
        try await store.write(["product": .string("app"), "amount": .double(8), "date": .date(noon)], entity: "payment", uuid: "p2")

        try await store.delete(entity: "payment", uuid: "p1")

        let rows = try await store.aggregate(entity: "payment", view: "low")
        #expect(rows.first?.count == 1)
        // The extremum cannot be un-applied without a rescan, so it stays at the deleted min.
        #expect(rows.first?.value == 2)
    }

    @Test("Series exposes cells at bucket resolution")
    func series() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .hour, sum: "amount")])
        try await writePayments([2, 3])
        try await store.write(
            ["product": .string("app"), "amount": .double(10), "date": .date(noon.addingTimeInterval(3_600))],
            entity: "payment"
        )

        let points = try await store.series(entity: "payment", view: "revenue")

        #expect(points.count == 2)
        #expect(points.first == AggregateSeriesPoint(group: "app", date: noon, count: 2, value: 5))
        #expect(points.last == AggregateSeriesPoint(group: "app", date: noon.addingTimeInterval(3_600), count: 1, value: 10))
    }

    @Test("MIN view keeps the smallest value")
    func minView() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await writePayments([5, 2, 8])

        let rows = try await store.aggregate(entity: "payment", view: "low")
        #expect(rows.count == 1)
        #expect(rows.first?.count == 3)
        #expect(rows.first?.value == 2)
    }

    @Test("MAX view keeps the largest value")
    func maxView() async throws {
        try await publishPayment(views: [AggregateView(name: "high", max: "amount")])
        try await writePayments([5, 2, 8])

        let rows = try await store.aggregate(entity: "payment", view: "high")
        #expect(rows.first?.value == 8)
    }

    @Test("AVG derives from a sum view")
    func average() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await writePayments([2.5, 1.5])

        let rows = try await store.aggregate(entity: "payment", view: "revenue")
        #expect(rows.first?.value == 4)
        #expect(rows.first?.average == 2)
    }

    @Test("GROUP BY and HAVING work over totals")
    func groupByHaving() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", sum: "amount")])
        try await writePayments([1, 2, 3], product: "app")
        try await writePayments([10], product: "bundle")

        let totals = try await store.totals(entity: "payment", view: "revenue")
        #expect(totals.map(\.group) == ["app", "bundle"])
        #expect(totals.first?.value == 6)

        let frequent = try await store.totals(entity: "payment", view: "revenue") { $0.count >= 2 }
        #expect(frequent.map(\.group) == ["app"])
    }

    @Test("Aggregate rows respect the date range")
    func dateRange() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", sum: "amount")])
        try await writePayments([1])
        try await store.write(["product": .string("app"), "amount": .double(9), "date": .date(noon.addingTimeInterval(86_400))], entity: "payment")

        let rows = try await store.aggregate(entity: "payment", view: "revenue", from: Date(timeIntervalSince1970: 86_400))
        #expect(rows.count == 1)
        #expect(rows.first?.value == 9)
    }

    @Test("DISTINCT returns unique values")
    func distinct() async throws {
        try await publishPayment(views: [])
        try await writePayments([1], product: "app")
        try await writePayments([2], product: "bundle")
        try await writePayments([3], product: "app")

        let products = try await store.distinct(entity: "payment", field: "product")
        #expect(Set(products.map(\.canonical)) == ["app", "bundle"])
        #expect(products.count == 2)
    }

    @Test("Stats views expose variance and standard deviation")
    func stats() async throws {
        try await publishPayment(views: [AggregateView(name: "spread", stats: "amount")])
        try await writePayments([2, 4, 4, 4, 5, 5, 7, 9])

        let rows = try await store.aggregate(entity: "payment", view: "spread")
        let row = try #require(rows.first)
        #expect(row.count == 8)
        #expect(row.average == 5)
        #expect(row.variance == 4)
        #expect(row.standardDeviation == 2)
    }

    @Test("Percentiles interpolate within histogram buckets")
    func percentile() async throws {
        try await publishPayment(views: [AggregateView(name: "latency", histogram: AggregateView.Histogram(field: "amount", bounds: [10, 50, 100]))])
        try await writePayments([5, 20, 60, 200])

        let median = try await store.percentile(0.5, entity: "payment", view: "latency")
        #expect(median == 50)
        let low = try await store.percentile(0.1, entity: "payment", view: "latency")
        #expect(low == 10)
        let high = try await store.percentile(0.99, entity: "payment", view: "latency")
        #expect(high == 100)
    }

    @Test("Percentile of an empty histogram is nil")
    func emptyPercentile() async throws {
        try await publishPayment(views: [AggregateView(name: "latency", histogram: AggregateView.Histogram(field: "amount", bounds: [10]))])
        #expect(try await store.percentile(0.5, entity: "payment", view: "latency") == nil)
    }

    @Test("A histogram with unsorted bounds is rejected")
    func histogramBounds() {
        let definition = makeDefinition(
            entity: "payment",
            fields: [
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ], envelopeDate: "date", views: [AggregateView(name: "broken", histogram: AggregateView.Histogram(field: "amount", bounds: [50, 10]))])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("A view with two metrics is rejected")
    func metricExclusivity() async throws {
        let definition = makeDefinition(
            entity: "payment",
            fields: [
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ], envelopeDate: "date", views: [AggregateView(name: "broken", sum: "amount", min: "amount")])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("A batched write aggregates like the equivalent single writes")
    func batchAggregation() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .hour, sum: "amount")])
        try await store.write(
            [
                EntityWrite(values: ["product": .string("app"), "amount": .double(2), "date": .date(noon)]),
                EntityWrite(values: ["product": .string("app"), "amount": .double(3), "date": .date(noon)]),
                EntityWrite(values: ["product": .string("app"), "amount": .double(10), "date": .date(noon.addingTimeInterval(3_600))]),
            ], entity: "payment")

        let points = try await store.series(entity: "payment", view: "revenue")

        #expect(points.count == 2)
        #expect(points.first == AggregateSeriesPoint(group: "app", date: noon, count: 2, value: 5))
        #expect(points.last == AggregateSeriesPoint(group: "app", date: noon.addingTimeInterval(3_600), count: 1, value: 10))
    }

    @Test("A batched write folds MIN across the whole batch")
    func batchMinFold() async throws {
        try await publishPayment(views: [AggregateView(name: "low", min: "amount")])
        try await store.write(
            [5, 2, 8].map { EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)]) },
            entity: "payment")

        let rows = try await store.aggregate(entity: "payment", view: "low")
        #expect(rows.count == 1)
        #expect(rows.first?.count == 3)
        #expect(rows.first?.value == 2)
    }

    @Test("A batched write touches each grid record once")
    func batchGridWrites() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .hour, sum: "amount")])
        try await store.write(
            [1, 2, 3, 4].map { EntityWrite(values: ["product": .string("app"), "amount": .double($0), "date": .date(noon)]) },
            entity: "payment")

        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 1)
    }

    @Test("A lifetime view keeps one running total per category, without an envelope date")
    func lifetimeView() async throws {
        // No envelope date: only a lifetime view can aggregate this entity.
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ], views: [AggregateView(name: "by_product", groupBy: "product", bucket: .lifetime, sum: "amount")]))

        let first = try await store.write(["product": .string("app"), "amount": .double(10)], entity: "sale")
        try await store.write(["product": .string("app"), "amount": .double(5)], entity: "sale")
        try await store.write(["product": .string("book"), "amount": .double(2)], entity: "sale")

        var totals = try await store.totals(entity: "sale", view: "by_product")
        #expect(totals.first { $0.group == "app" }?.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 15)
        #expect(totals.first { $0.group == "book" }?.value == 2)
        // One grid record per category — no time grid.
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 2)

        // Deletes reverse their contribution like any other view.
        try await store.delete(entity: "sale", uuid: first)
        totals = try await store.totals(entity: "sale", view: "by_product")
        #expect(totals.first { $0.group == "app" }?.count == 1)
        #expect(totals.first { $0.group == "app" }?.value == 5)

        // A time-bucketed view still demands the envelope date.
        let dated = makeDefinition(
            entity: "sale2",
            fields: [FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"))],
            views: [AggregateView(name: "hourly", groupBy: "product", bucket: .hour)])
        #expect(throws: SchemaError.self) { try dated.validate() }
    }
}
