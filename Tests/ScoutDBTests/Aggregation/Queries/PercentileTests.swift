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

@Suite("Percentiles, read off a histogram")
struct PercentileTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    static let bounds: [Double] = [10, 20, 30, 40]

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
    }

    private func publishRequest(
        aggregates: [AggregateDefinition] = [
            AggregateDefinition(histogram: "latency", bounds: PercentileTests.bounds, group: nil, date: nil)
        ]
    ) async throws {
        try await registry.publish(
            makeDefinition(
                entity: "request",
                fields: [
                    FieldDefinition(name: "route", type: .string, storage: .slot(.string, "s_01")),
                    FieldDefinition(name: "latency", type: .double, storage: .slot(.double, "d_00")),
                ],
                aggregates: aggregates
            )
        )
    }

    private func write(_ latencies: [Double?], route: String = "/home") async throws {
        for (index, latency) in latencies.enumerated() {
            var values: [String: RecordValue] = ["route": .string(route)]
            if let latency {
                values["latency"] = .double(latency)
            }
            try await store.write([EntityWrite(values: values, uuid: "r-\(index)")], entity: "request")
        }
    }

    private var buckets: [CKRecord] {
        database.records.filter { $0.recordType == "Vector" }
    }

    @Test("A percentile lands inside its bucket and reads only the buckets")
    func interpolatesWithinTheBucket() async throws {
        try await publishRequest()
        try await write([5, 15, 15, 25, 35])

        #expect(buckets.count == 4)

        let median = try #require(try await store.query("request").percentile(0.5, of: "latency"))
        #expect(median > 10 && median < 20)

        let ninety = try #require(try await store.query("request").percentile(0.9, of: "latency"))
        #expect(ninety > 30 && ninety <= 40)
    }

    @Test("The open buckets answer with the edge they have")
    func openBucketsAnswerWithTheirEdge() async throws {
        try await publishRequest()
        try await write([1, 2, 3])

        #expect(try await store.query("request").percentile(0.5, of: "latency") == 10)

        try await write([100, 200, 300], route: "/other")

        #expect(try await store.query("request").percentile(1, of: "latency") == 40)
    }

    @Test("A record without the field is counted in no bucket")
    func missingValuesCountNowhere() async throws {
        try await publishRequest()
        try await write([15, nil, nil])

        #expect(buckets.count == 1)
        #expect(buckets.first?.cells() == 1)
    }

    @Test("Nothing written reads back as no percentile at all")
    func emptyHistogramAnswersNil() async throws {
        try await publishRequest()

        #expect(try await store.query("request").percentile(0.5, of: "latency") == nil)
    }

    @Test("A rewrite moves the record from the bucket it left to the one it lands in")
    func rewriteMovesBetweenBuckets() async throws {
        try await publishRequest()
        try await store.write(
            [EntityWrite(values: ["route": .string("/home"), "latency": .double(15)], uuid: "r-0")],
            entity: "request"
        )
        try await store.write(
            [EntityWrite(values: ["route": .string("/home"), "latency": .double(35)], uuid: "r-0")],
            entity: "request"
        )

        var counts: [String: Double] = [:]
        for bin in 0...PercentileTests.bounds.count {
            let group = RecordValue.int(Int64(bin)).canonical
            let vector = database.vector("request", "histogram_latency", group: group, week: Date().weekStart)
            counts[group] = vector?.cells() ?? 0
        }

        #expect(counts[RecordValue.int(1).canonical] == 0)
        #expect(counts[RecordValue.int(3).canonical] == 1)
    }

    @Test("A histogram never answers the folds that count every record")
    func histogramDoesNotServeCount() async throws {
        try await publishRequest(
            aggregates: [
                AggregateDefinition(histogram: "latency", bounds: PercentileTests.bounds, group: nil, date: nil),
                AggregateDefinition(group: "route"),
            ]
        )
        try await write([15, nil, nil])

        #expect(try await store.query("request").count() == 3)
    }

    @Test("A rank outside 0...1 is refused rather than clamped")
    func rankOutsideTheRangeThrows() async throws {
        try await publishRequest()

        await #expect(throws: SchemaError.unsupportedQuery(.rankOutOfRange(95))) {
            try await store.query("request").percentile(95, of: "latency")
        }
    }

    @Test("A percentile of an unhistogrammed field throws instead of scanning")
    func withoutAHistogramItThrows() async throws {
        try await publishRequest(aggregates: [AggregateDefinition(group: "route")])

        await #expect(
            throws: SchemaError.unsupportedQuery(.noHistogram(entity: "request", field: "latency"))
        ) {
            try await store.query("request").percentile(0.5, of: "latency")
        }
    }

    @Test("A filtered percentile throws, since the bucket spends the grouping")
    func filteredPercentileThrows() async throws {
        try await publishRequest()

        await #expect(throws: SchemaError.unsupportedQuery(.filteredHistogram)) {
            try await store.query("request").filter("route" == "/home").percentile(0.5, of: "latency")
        }
    }

    @Test("A histogram takes neither a grouping nor bounds it cannot bucket by")
    func validationRejectsTheShapesThatCannotWork() throws {
        let field = FieldDefinition(name: "latency", type: .double, storage: .slot(.double, "d_00"))

        func definition(_ aggregate: AggregateDefinition) -> EntityDefinition {
            makeDefinition(entity: "request", fields: [field], aggregates: [aggregate])
        }

        let grouped = AggregateDefinition(histogram: "latency", bounds: [10], group: "latency", date: nil)

        #expect(throws: SchemaError.invalidDefinition(.groupedHistogram(aggregate: "histogram_latency"))) {
            try definition(grouped).validate()
        }
        #expect(throws: SchemaError.invalidDefinition(.invalidBounds(aggregate: "histogram_latency"))) {
            try definition(AggregateDefinition(histogram: "latency", bounds: [], group: nil, date: nil)).validate()
        }
        #expect(throws: SchemaError.invalidDefinition(.invalidBounds(aggregate: "histogram_latency"))) {
            try definition(AggregateDefinition(histogram: "latency", bounds: [20, 10], group: nil, date: nil))
                .validate()
        }
        #expect(throws: SchemaError.invalidDefinition(.invalidBounds(aggregate: "histogram_latency"))) {
            try definition(AggregateDefinition(histogram: "latency", bounds: [10, 10], group: nil, date: nil))
                .validate()
        }
        #expect(throws: SchemaError.invalidDefinition(.nonNumericMetric(aggregate: "histogram_route", field: "route")))
        {
            try definition(AggregateDefinition(histogram: "route", bounds: [10], group: nil, date: nil)).validate()
        }
    }

    @Test("The bounds name the bucket a value falls in")
    func bucketing() {
        let histogram = AggregateDefinition.Histogram(field: "latency", bounds: Self.bounds)

        #expect(histogram.groupKeys == ["i0", "i1", "i2", "i3", "i4"])
        #expect(histogram.groupKey(of: 5) == "i0")
        #expect(histogram.groupKey(of: 10) == "i1")
        #expect(histogram.groupKey(of: 39.9) == "i3")
        #expect(histogram.groupKey(of: 40) == "i4")
        #expect(histogram.groupKey(of: 4_000) == "i4")
    }
}
