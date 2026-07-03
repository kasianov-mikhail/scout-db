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
}
