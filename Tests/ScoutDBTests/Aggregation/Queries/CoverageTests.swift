//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Hours before an aggregate joined")
struct CoverageTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    let morning = Date(timeIntervalSince1970: 36_000)

    var noon: Date {
        morning.hour(2)
    }

    var later: Date {
        Date().nextHourStart.hour(1)
    }

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double, .required)
            .field("date", .timestamp)
            .create()
    }

    @Test("A sum joining on an update totals the records written before it, each once")
    func totalsCoverEarlierRecords() async throws {
        try await write("t-1", queue: "a", weight: 2, date: morning)
        try await write("t-2", queue: "a", weight: 3, date: noon)
        try await write("t-3", queue: "b", weight: 5, date: noon)
        try await declareWeight()
        try await write("t-4", queue: "a", weight: 7, date: morning)
        try await write("t-5", queue: "a", weight: 11, date: later)

        let totals = try await store.query("ticket").totals("weight", metric: .sum, group: "queue")

        #expect(totals == [AggregateTotal(group: "a", value: 23), AggregateTotal(group: "b", value: 5)])
    }

    @Test("A series over hours before the sum joined reads them from the records")
    func seriesCoversEarlierHours() async throws {
        try await write("t-1", queue: "a", weight: 2, date: morning)
        try await write("t-2", queue: "b", weight: 5, date: noon)
        try await declareWeight()
        try await write("t-3", queue: "a", weight: 7, date: morning)
        try await write("t-4", queue: "a", weight: 11, date: later)

        let points = try await store.query("ticket")
            .series("weight", metric: .sum, group: "queue", in: morning.weekStart..<later.hour(1))

        #expect(
            points == [
                SeriesPoint(group: "a", date: morning, value: 9),
                SeriesPoint(group: "b", date: noon, value: 5),
                SeriesPoint(group: "a", date: later, value: 11),
            ]
        )
    }

    @Test("An aggregate built on creation answers from its vectors alone")
    func creationReadsNoRecords() async throws {
        try await store.schema("invoice")
            .field("client", .string, .required)
            .field("amount", .double, .required)
            .field("date", .timestamp)
            .sum("amount", by: "client", at: "date")
            .create()
        try await store.write(
            [EntityWrite(values: ["client": "c", "amount": .double(4), "date": .date(morning)], uuid: "i-1")],
            entity: "invoice"
        )
        database.resetRequests()

        let totals = try await store.query("invoice").totals("amount", metric: .sum, group: "client")

        #expect(totals == [AggregateTotal(group: "c", value: 4)])
        #expect(database.requests[.query] == 0)
    }

    @Test("Declaring the aggregate again keeps the hour it started counting")
    func redeclarationKeepsTheStart() async throws {
        try await declareWeight()
        let first = try await start()

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double, .required)
            .field("date", .timestamp)
            .field("note", .string)
            .sum("weight", by: "queue", at: "date")
            .update()

        #expect(first != nil)
        #expect(try await start() == first)
    }

    @Test("The start survives the round trip through the published descriptor")
    func startRoundTrips() throws {
        let start = Date(timeIntervalSince1970: 7_200)
        var aggregate = AggregateDefinition(metric: .sum, field: "weight", group: "queue")
        aggregate.since = start

        let decoded = try JSONDecoder().decode(AggregateDefinition.self, from: JSONEncoder().encode(aggregate))
        let legacy = try JSONDecoder().decode(AggregateDefinition.self, from: Data(#"{"groupBy":"queue"}"#.utf8))

        #expect(decoded.since == start)
        #expect(legacy.since == nil)
    }

    private func declareWeight() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double, .required)
            .field("date", .timestamp)
            .sum("weight", by: "queue", at: "date")
            .update()
    }

    private func write(_ uuid: String, queue: String, weight: Double, date: Date) async throws {
        let values: [String: RecordValue] = ["queue": .string(queue), "weight": .double(weight), "date": .date(date)]
        try await store.write([EntityWrite(values: values, uuid: uuid)], entity: "ticket")
    }

    private func start() async throws -> Date? {
        try await registry.definition(for: "ticket").aggregates.first { $0.measure == .sum("weight") }?.since
    }
}
