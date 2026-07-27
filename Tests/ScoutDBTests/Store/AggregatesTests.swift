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
                ], envelopeDate: "date", views: views))
    }

    private func writePayments(_ amounts: [Double], product: String = "app") async throws {
        for amount in amounts {
            try await store.write(["product": .string(product), "amount": .double(amount), "date": .date(noon)], entity: "payment")
        }
    }

    @Test("A grid slot named before separators were escaped is still adopted")
    func legacyGridSlotAdoption() async throws {
        try await publishPayment(views: [AggregateView(name: "daily", groupBy: "product", bucket: .day)])

        let group = "a|b"
        let period = EntityCoder.periodStart(of: .month, for: noon)
        let legacyKey = "payment|daily|\(group)|\(period.millisecondsSince1970)"
        let legacyName = "grid-" + SHA256.hash(data: Data(legacyKey.utf8)).hexString
        #expect(legacyName != "grid-" + contentDigest(of: ["payment", "daily", group, "\(period.millisecondsSince1970)"]))

        let legacy = CKRecord(recordType: "Aggregate", recordID: CKRecord.ID(recordName: legacyName))
        legacy["entity"] = "payment"
        legacy["view"] = "daily"
        legacy["group_key"] = group
        legacy["date"] = period
        legacy["c_00"] = Int64(5)
        try await database.write(records: [legacy])

        try await writePayments([1], product: group)

        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 1)
        #expect(try await store.totals(entity: "payment", view: "daily").map(\.count) == [6])
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

        try await store.write(["user": .string("u1"), "amount": .double(10), "date": .date(noon)], entity: "meter")
        try await store.write(["user": .string("u1"), "amount": .double(25), "date": .date(noon)], entity: "meter")

        #expect(try await store.read(entity: "meter").count == 1)
        let rows = try await store.aggregate(entity: "meter", view: "revenue")
        #expect(rows.first?.count == 1)
        #expect(rows.first?.value == 25)
    }

    @Test("A sharded view spreads a hot slot over several records and reads back whole")
    func shardedView() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", bucket: .lifetime, sum: "amount", shards: 3)])
        for index in 0..<6 {
            try await store.write(
                ["product": .string("app"), "amount": .double(Double(index + 1)), "date": .date(noon)], entity: "payment", uuid: "p-\(index)")
        }
        let shards = Set((0..<6).map { GridAggregator.shard(of: "p-\($0)", among: 3) })
        #expect(shards.count > 1)
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == shards.count)

        let rows = try await store.aggregate(entity: "payment", view: "revenue")
        #expect(rows.count == 1)
        #expect(rows.first?.count == 6)
        #expect(rows.first?.value == 21)

        try await store.delete(entity: "payment", uuid: "p-3")
        #expect(try await store.totals(entity: "payment", view: "revenue").map(\.count) == [5])
        #expect(try await store.query("payment").count() == 5)

        let invalid = makeDefinition(
            entity: "e",
            fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))],
            views: [AggregateView(name: "x", bucket: .lifetime, shards: 1)])
        #expect(throws: SchemaError.self) { try invalid.validate() }
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

    @Test("The shared calendar is Sunday-anchored so weekday cells date correctly")
    func weekdaySeriesDatesLineUp() async throws {
        #expect(EntityCoder.calendar.firstWeekday == 1)

        try await publishPayment(views: [AggregateView(name: "byday", groupBy: "product", bucket: .weekday, sum: "amount")])
        let thursday = Date(timeIntervalSince1970: 36_000)
        try await store.write(["product": .string("app"), "amount": .double(2), "date": .date(thursday)], entity: "payment")

        let point = try #require(try await store.series(entity: "payment", view: "byday").first)
        #expect(EntityCoder.calendar.component(.weekday, from: point.date) == EntityCoder.calendar.component(.weekday, from: thursday))
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

    @Test("A range opening mid-period keeps the rest of that period")
    func rangeInsidePeriod() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .day, sum: "amount")])
        let midMonth = noon.addingTimeInterval(14 * 86_400)
        try await writePayments([1])
        try await store.write(["product": .string("app"), "amount": .double(9), "date": .date(midMonth)], entity: "payment")

        let month = EntityCoder.periodStart(of: .month, for: noon)
        let fifteenth = EntityCoder.periodStart(of: .day, for: midMonth)

        let tail = try await store.aggregate(entity: "payment", view: "revenue", from: fifteenth)
        #expect(tail == [AggregateRow(group: "app", period: month, count: 1, value: 9, squares: nil)])

        let head = try await store.aggregate(entity: "payment", view: "revenue", to: fifteenth)
        #expect(head == [AggregateRow(group: "app", period: month, count: 1, value: 1, squares: nil)])

        let whole = try await store.aggregate(entity: "payment", view: "revenue", from: month)
        #expect(whole.first?.value == 10)
        #expect(try await store.totals(entity: "payment", view: "revenue", from: fifteenth).first?.value == 9)
    }

    @Test("A series range drops the cells outside it")
    func seriesInsidePeriod() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .hour, sum: "amount")])
        let later = noon.addingTimeInterval(2 * 3_600)
        try await writePayments([2])
        try await store.write(["product": .string("app"), "amount": .double(9), "date": .date(later)], entity: "payment")

        let points = try await store.series(entity: "payment", view: "revenue", from: noon.addingTimeInterval(3_600))
        #expect(points == [AggregateSeriesPoint(group: "app", date: later, count: 1, value: 9)])
    }

    @Test("A stats range narrows the squares along with the values")
    func statsInsidePeriod() async throws {
        try await publishPayment(views: [AggregateView(name: "spread", bucket: .day, stats: "amount")])
        let midMonth = noon.addingTimeInterval(14 * 86_400)
        try await writePayments([100])
        for amount: Double in [2, 4, 4, 4, 5, 5, 7, 9] {
            try await store.write(["product": .string("app"), "amount": .double(amount), "date": .date(midMonth)], entity: "payment")
        }

        let fifteenth = EntityCoder.periodStart(of: .day, for: midMonth)
        let row = try #require(try await store.aggregate(entity: "payment", view: "spread", from: fifteenth).first)
        #expect(row.count == 8)
        #expect(row.average == 5)
        #expect(row.variance == 4)
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

    @Test("DISTINCT reads a covering view's grid instead of scanning")
    func distinctThroughLifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"), required: true),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ], views: [AggregateView(name: "by_product", groupBy: "product", bucket: .lifetime)]))
        try await store.write(["product": .string("app"), "amount": .double(10)], entity: "sale")
        try await store.write(["product": .string("app"), "amount": .double(5)], entity: "sale")
        try await store.write(["product": .string("book"), "amount": .double(2)], entity: "sale", uuid: "s-book")

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" })
        grid["group_key"] = "pen"
        #expect(try await store.distinct(entity: "sale", field: "product").map(\.canonical) == ["app", "pen"])
        #expect(
            try await store.distinct(entity: "sale", field: "product", filters: [EntityStore.Filter(field: "product", op: .equals, value: .string("app"))]).map(
                \.canonical) == ["app"])

        grid["group_key"] = "book"
        try await store.delete(entity: "sale", uuid: "s-book")
        #expect(try await store.distinct(entity: "sale", field: "product").map(\.canonical) == ["app"])

        #expect(
            Set(
                try await store.distinct(entity: "sale", field: "product", filters: [EntityStore.Filter(field: "amount", op: .greaterThan, value: .double(1))])
                    .map(\.canonical)) == ["app"])
    }

    @Test("A grid-served DISTINCT rebuilds typed values from group keys")
    func distinctRebuildsTypedValues() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "reading",
                fields: [
                    FieldDefinition(name: "level", type: .int, storage: .slot(.int, "i_00"), required: true)
                ], views: [AggregateView(name: "by_level", groupBy: "level", bucket: .lifetime)]))
        try await store.write(["level": .int(5)], entity: "reading")
        try await store.write(["level": .int(12)], entity: "reading")
        try await store.write(["level": .int(5)], entity: "reading")

        let levels = try await store.distinct(entity: "reading", field: "level")
        #expect(levels.count == 2)
        #expect(levels.contains(.int(5)) && levels.contains(.int(12)))
    }

    @Test("DISTINCT of an optional field scans even under a covering view")
    func distinctOptionalFieldScans() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "device",
                fields: [
                    FieldDefinition(name: "model", type: .string, storage: .slot(.string, "s_00"))
                ], views: [AggregateView(name: "by_model", groupBy: "model", bucket: .lifetime)]))
        try await store.write(["model": .string("mk1")], entity: "device")
        try await store.write([:], entity: "device")

        #expect(try await store.distinct(entity: "device", field: "model") == [.string("mk1")])
    }

    @Test("A single-group aggregate read narrows to that group's rows")
    func aggregateOneGroup() async throws {
        try await publishPayment(views: [AggregateView(name: "revenue", groupBy: "product", bucket: .day, sum: "amount")])
        try await writePayments([10, 5], product: "app")
        try await writePayments([2], product: "book")

        let rows = try await store.aggregate(entity: "payment", view: "revenue", group: "book")
        #expect(rows.map(\.group) == ["book"])
        #expect(rows.first?.value == 2)
        #expect(try await store.totals(entity: "payment", view: "revenue", group: "app").map(\.value) == [15])
        #expect(try await store.series(entity: "payment", view: "revenue", group: "book").map(\.count) == [1])
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
        #expect(database.records.filter { $0.recordType == "Aggregate" }.count == 2)

        try await store.delete(entity: "sale", uuid: first)
        totals = try await store.totals(entity: "sale", view: "by_product")
        #expect(totals.first { $0.group == "app" }?.count == 1)
        #expect(totals.first { $0.group == "app" }?.value == 5)

        let dated = makeDefinition(
            entity: "sale2",
            fields: [FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"))],
            views: [AggregateView(name: "hourly", groupBy: "product", bucket: .hour)])
        #expect(throws: SchemaError.self) { try dated.validate() }
    }

    @Test("count() reads a covering lifetime view's grid instead of scanning")
    func countThroughLifetimeView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sale",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                ], views: [AggregateView(name: "by_product", groupBy: "product", bucket: .lifetime)]))
        try await store.write(["product": .string("app"), "amount": .double(10)], entity: "sale")
        try await store.write(["product": .string("app"), "amount": .double(5)], entity: "sale")
        try await store.write(["product": .string("book"), "amount": .double(2)], entity: "sale")

        #expect(try await store.query("sale").count() == 3)
        #expect(try await store.query("sale").filter("product", .equals, "app").count() == 2)
        #expect(try await store.query("sale").limit(1).count() == 1)

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" })
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
                ], views: [AggregateView(name: "by_kind", groupBy: "kind", bucket: .lifetime, sum: "price")]))
        try await store.write(["kind": .string("a"), "price": .double(10)], entity: "ticket")
        try await store.write(["kind": .string("a"), "price": .double(5)], entity: "ticket")
        try await store.write(["kind": .string("b"), "price": .double(2)], entity: "ticket")
        try await store.write(["kind": .string("c"), "price": .double(4)], entity: "ticket")

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "b" })
        grid["c_00"] = Int64(41)
        grid["f_00"] = Double(100)

        #expect(try await store.query("ticket").filter("kind", .in, .strings(["b", "c"])).count() == 42)
        #expect(
            try await store.query("ticket")
                .group {
                    $0.filter("kind", .equals, "a")
                    $0.filter("kind", .equals, "b")
                }.count() == 43)
        #expect(
            try await store.query("ticket")
                .group {
                    $0.filter("kind", .equals, "b")
                    $0.filter("kind", .equals, "b")
                }.count() == 41)
        #expect(
            try await store.counts(by: "kind", entity: "ticket", filters: [EntityStore.Filter(field: "kind", op: .in, value: .strings(["b", "c"]))])
                == ["b": 41, "c": 1])
        #expect(try await store.query("ticket").filter("kind", .in, .strings(["a", "b"])).sum("price") == 115)

        #expect(
            try await store.query("ticket")
                .group {
                    $0.filter("kind", .equals, "a")
                    $0.filter("price", .equals, .double(2))
                }.count() == 3)
    }

    @Test("A strict integer threshold counts as the half-open bound it equals")
    func countThroughIntegerThreshold() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "basket",
                fields: [
                    FieldDefinition(name: "units", type: .int, storage: .slot(.int, "i_00"), required: true),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date",
                views: [AggregateView(name: "sizes", histogram: AggregateView.Histogram(field: "units", bounds: [4, 16]))]))
        for units: Int64 in [1, 5, 12, 16, 20, 30] {
            try await store.write(["units": .int(units), "date": .date(noon)], entity: "basket")
        }

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["view"] as? String == "sizes" })
        grid["c_02"] = Int64(40)

        #expect(try await store.query("basket").filter("units", .greaterThan, .int(15)).count() == 40)
        #expect(try await store.query("basket").filter("units", .greaterThanOrEquals, .int(16)).count() == 40)
        #expect(try await store.query("basket").filter("units", .lessThanOrEquals, .int(15)).count() == 3)
        #expect(try await store.query("basket").filter("units", .lessThan, .int(16)).count() == 3)

        #expect(try await store.query("basket").filter("units", .greaterThan, .int(14)).count() == 3)
    }

    @Test("count() over an aligned date range reads the view's cells instead of scanning")
    func countThroughRange() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "visit",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: [AggregateView(name: "hourly", groupBy: "product", bucket: .hour)]))
        func hour(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(offset * 3_600)) }
        try await store.write(["product": .string("app"), "date": .date(hour(0))], entity: "visit")
        try await store.write(["product": .string("app"), "date": .date(hour(1))], entity: "visit")
        try await store.write(["product": .string("book"), "date": .date(hour(1))], entity: "visit")
        try await store.write(["product": .string("app"), "date": .date(hour(30))], entity: "visit")

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "app" && $0["c_00"] != nil })
        grid["c_00"] = Int64(41)

        #expect(
            try await store.query("visit")
                .filter("date", .greaterThanOrEquals, .date(hour(0)))
                .filter("date", .lessThan, .date(hour(2)))
                .count() == 43)
        #expect(try await store.query("visit").filter("date", .greaterThanOrEquals, .date(hour(1))).filter("date", .lessThan, .date(hour(2))).count() == 2)
        #expect(try await store.query("visit").filter("date", .greaterThanOrEquals, .date(hour(2))).count() == 1)
        #expect(
            try await store.query("visit")
                .filter("product", .equals, "app")
                .filter("date", .greaterThanOrEquals, .date(hour(0)))
                .filter("date", .lessThan, .date(hour(2)))
                .count() == 42)

        let misaligned = Date(timeIntervalSince1970: 1_800)
        #expect(try await store.query("visit").filter("date", .lessThan, .date(misaligned)).count() == 1)
    }

    @Test("count() at a histogram bound reads the histogram's cells instead of scanning")
    func countThroughHistogram() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "metric",
                fields: [
                    FieldDefinition(name: "value", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date",
                views: [AggregateView(name: "dist", histogram: AggregateView.Histogram(field: "value", bounds: [1, 5, 10]))]))
        let date = Date(timeIntervalSince1970: 0)
        for value in [0.5, 3, 7, 12] {
            try await store.write(["value": .double(value), "date": .date(date)], entity: "metric")
        }

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["view"] as? String == "dist" })
        grid["c_00"] = Int64(41)

        #expect(try await store.query("metric").filter("value", .lessThan, .double(5)).count() == 42)
        #expect(try await store.query("metric").filter("value", .greaterThanOrEquals, .double(5)).count() == 2)
        #expect(
            try await store.query("metric")
                .filter("value", .greaterThanOrEquals, .double(1))
                .filter("value", .lessThan, .double(10))
                .count() == 2)
        #expect(try await store.query("metric").filter("value", .lessThan, .double(3)).count() == 1)
    }

    private func publishLedger(required: Bool = true) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ledger",
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00"), required: required),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), required: required),
                ], views: [AggregateView(name: "by_product", groupBy: "product", bucket: .lifetime, sum: "amount")]))
        for (product, amount) in [("app", 10.0), ("app", 6.0), ("book", 4.0)] {
            try await store.write(["product": .string(product), "amount": .double(amount)], entity: "ledger")
        }
    }

    private func tamperedBookSlot() throws -> CKRecord {
        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" })
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

        #expect(try await store.query("ledger").minimum("amount") == 4)
        #expect(try await store.query("ledger").maximum("amount") == 10)
    }

    @Test("Grouped folds and count(by:) read the grouping view's grid")
    func groupedFoldThroughLifetimeView() async throws {
        try await publishLedger()
        _ = try tamperedBookSlot()

        #expect(try await store.query("ledger").sum("amount", by: "product") == ["app": 16, "book": 40])
        #expect(try await store.query("ledger").count(by: "product") == ["app": 2, "book": 3])
        #expect(try await store.query("ledger").average("amount", by: "product") == ["app": 8, "book": 40.0 / 3])
        #expect(try await store.query("ledger").minimum("amount", by: "product") == ["app": 6, "book": 4])
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
    func groupScopedGridRead() async throws {
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

    @Test("A grid read projects the cells it folds, and only cells the schema declares")
    func gridReadProjection() async throws {
        try await publishLedger()
        let watched = GridQueries(backing: database)
        let reader = EntityStore(database: watched, registry: registry)

        _ = try await reader.query("ledger").count()
        var keys = try #require(watched.grid.last?.keys)
        #expect(keys.contains("c_00") && keys.contains("c_31"))
        #expect(keys.contains("c_32") == false)
        #expect(keys.contains { $0.hasPrefix("f_") } == false)

        _ = try await reader.query("ledger").sum("amount")
        keys = try #require(watched.grid.last?.keys)
        #expect(keys.contains("f_00") && keys.contains("f_30"))
        #expect(keys.contains("f_31") == false)

        _ = try await reader.aggregate(entity: "ledger", view: "by_product")
        keys = try #require(watched.grid.last?.keys)
        #expect(Set(keys).isSuperset(of: ["date", "group_key", "c_63", "f_62"]))
        #expect(keys.contains("f_31") == false && keys.contains("f_63") == false)
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
                ], views: [AggregateView(name: "by_product", groupBy: "product", bucket: .lifetime, sum: "amount")]))
        try await store.write(["product": .string("app"), "amount": .double(10), "tax": .double(1)], entity: "fee")
        try await store.write(["product": .string("book"), "amount": .double(4), "tax": .double(2)], entity: "fee")

        let grid = try #require(database.records.first { $0.recordType == "Aggregate" && $0["group_key"] as? String == "book" })
        grid["c_00"] = Int64(3)
        grid["f_00"] = 40.0

        #expect(try await store.query("fee").sum("tax") == 3)
        #expect(try await store.query("fee").count(by: "amount") == ["d10.0": 1, "d4.0": 1])
        #expect(try await store.query("fee").exclude("product", .equals, "app").sum("amount") == 4)
    }
}

/// Forwards to an in-memory database while recording every grid query — the
/// predicate it carried, the fields it asked for, and how many rows it moved.
private final class GridQueries: CloudDatabase, @unchecked Sendable {
    private let backing: InMemoryDatabase
    private let lock = NSLock()
    private var log: [(query: CKQuery, keys: [CKRecord.FieldKey]?, matched: Int)] = []

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    var grid: [(query: CKQuery, keys: [CKRecord.FieldKey]?, matched: Int)] {
        lock.withLock { log.filter { $0.query.recordType == Aggregate.recordType } }
    }

    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let response = try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        lock.withLock { log.append((query, desiredKeys, response.matchResults.count)) }
        return response
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
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

    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try await backing.fetchRecords(ids: ids)
    }

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}
