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

@Suite("Coverage of an aggregate")
struct CoverageTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double, .required)
            .create()
    }

    @Test("An aggregate built on creation covers every hour")
    func creationCoversEverything() async throws {
        #expect(try await store.query("ticket").coverage(metric: .sum, group: "queue") == nil)
    }

    @Test("An aggregate joining on an update covers from the next whole hour")
    func updateStartsAtTheNextHour() async throws {
        let before = Date()
        try await declareWeight()
        let after = Date()

        let start = try #require(try await store.query("ticket").coverage("weight", metric: .sum, group: "queue"))

        #expect(start >= before.nextHourStart)
        #expect(start <= after.nextHourStart)
        #expect(start.timeIntervalSince1970.truncatingRemainder(dividingBy: Date.secondsPerHour) == 0)
    }

    @Test("Declaring the aggregate again keeps the hour it started counting")
    func redeclarationKeepsTheStart() async throws {
        try await declareWeight()
        let first = try await store.query("ticket").coverage("weight", metric: .sum, group: "queue")

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double, .required)
            .field("note", .string)
            .sum("weight", by: "queue")
            .update()

        #expect(try await store.query("ticket").coverage("weight", metric: .sum, group: "queue") == first)
        #expect(try await store.query("ticket").coverage(metric: .sum, group: "queue") == nil)
    }

    @Test("An average covers from the later of the two aggregates it divides")
    func averageTakesTheLaterStart() async throws {
        try await declareWeight()

        let total = try await store.query("ticket").coverage("weight", metric: .sum, group: "queue")

        #expect(total != nil)
        #expect(try await store.query("ticket").coverage("weight", metric: .average, group: "queue") == total)
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
            .sum("weight", by: "queue")
            .update()
    }
}
