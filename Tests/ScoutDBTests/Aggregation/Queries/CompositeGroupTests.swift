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

@Suite("Aggregates grouped by several fields")
struct CompositeGroupTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    let noon = Date(timeIntervalSince1970: 36_000)
    let groups = ["channel", "app_version"]

    var week: Range<Date> {
        noon.weekStart..<noon.weekStart.hour(Date.hoursPerWeek)
    }

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
    }

    @Test("A count by several fields keeps one cell per combination of their values")
    func countPerCombination() async throws {
        try await sessionSchema().count(by: groups, at: "start_date").create()
        try await writeSessions([("a", "1.0"), ("a", "1.0"), ("b", "2.0"), (nil, "1.0")])

        let points = try await store.query("session").series(metric: .sum, groups: groups, in: week)
        let totals = try await store.query("session").totals(metric: .sum, groups: groups)

        #expect(Set(points.map(\.groupValues)) == [["a", "1.0"], ["b", "2.0"], ["", "1.0"]])
        #expect(points.first { $0.groupValues == ["a", "1.0"] }?.value == 2)
        #expect(totals.map(\.value).reduce(0, +) == 4)
    }

    @Test("A value carrying the separator splits back as it was written")
    func separatorInValue() async throws {
        try await sessionSchema().count(by: groups, at: "start_date").create()
        try await writeSessions([("a|b", "1.0\\2")])

        let totals = try await store.query("session").totals(metric: .sum, groups: groups)

        #expect(totals.map(\.groupValues) == [["a|b", "1.0\\2"]])
    }

    @Test("A sum by several fields totals the field per combination")
    func sumPerCombination() async throws {
        try await store.schema("metric")
            .field("name", .string, .ungrouped)
            .field("app_version", .string, .ungrouped)
            .field("value", .int)
            .field("date", .timestamp)
            .sum("value", by: ["name", "app_version"], at: "date")
            .create()
        let metrics = [("exit", 2), ("exit", 3), ("launch", 7)]
        for (index, (name, value)) in metrics.enumerated() {
            let values: [String: RecordValue] = [
                "name": .string(name),
                "app_version": .string("1.0"),
                "value": .int(Int64(value)),
                "date": .date(noon),
            ]
            try await store.write([EntityWrite(values: values, uuid: "m-\(index)")], entity: "metric")
        }

        let totals = try await store.query("metric").totals("value", metric: .sum, groups: ["name", "app_version"])

        #expect(totals.map(\.groupValues) == [["exit", "1.0"], ["launch", "1.0"]])
        #expect(totals.map(\.value) == [5, 7])
    }

    @Test("A count by several fields that joins later folds the earlier records into their combinations")
    func laterCountCoversHistory() async throws {
        try await sessionSchema().create()
        try await writeSessions([("a", "1.0"), ("b", "2.0")])

        try await sessionSchema().count(by: groups, at: "start_date").update()

        let points = try await store.query("session")
            .series(metric: .sum, groups: groups, in: week.lowerBound..<Date().nextHourStart)

        #expect(Set(points.map(\.groupValues)) == [["a", "1.0"], ["b", "2.0"]])
    }

    @Test("A read by several fields refuses a filter")
    func filterRefused() async throws {
        try await sessionSchema().count(by: groups, at: "start_date").create()

        await #expect(throws: SchemaError.unsupportedQuery(.equalityOnly(group: "channel+app_version"))) {
            _ = try await store.query("session").filter("channel", .equals, "a")
                .totals(metric: .sum, groups: groups)
        }
    }

    @Test("Several grouping fields encode under their own key, one field under the old one")
    func encoding() throws {
        let composite = AggregateDefinition(
            metric: nil,
            field: nil,
            groups: groups,
            date: nil,
            shards: nil
        )
        let single = AggregateDefinition(group: "channel")

        let compositeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(composite)) as? [String: Any]
        let singleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(single)) as? [String: Any]
        let decoded = try JSONDecoder().decode(AggregateDefinition.self, from: JSONEncoder().encode(composite))

        #expect(compositeJSON?["groups"] as? [String] == ["channel", "app_version"])
        #expect(compositeJSON?["groupBy"] == nil)
        #expect(singleJSON?["groupBy"] as? String == "channel")
        #expect(decoded.groups == ["channel", "app_version"])
        #expect(composite.name == "by_channel+app_version")
    }

    @Test("An unknown field among the grouping fields is refused")
    func unknownField() async throws {
        let refusal = SchemaError.invalidDefinition(.unknownGrouping(aggregate: "by_channel+ghost", field: "ghost"))

        await #expect(throws: refusal) {
            try await sessionSchema().count(by: ["channel", "ghost"]).create()
        }
    }

    @Test("An update that declares nothing new publishes no version")
    func unchangedUpdate() async throws {
        try await sessionSchema().count(by: groups, at: "start_date").create()

        try await sessionSchema().count(by: groups, at: "start_date").update()
        try await sessionSchema().count(by: groups, at: "start_date").update()

        #expect(try await registry.definition(for: "session").version == 1)
    }

    private func sessionSchema() -> SchemaBuilder {
        store.schema("session")
            .field("channel", .string, .ungrouped)
            .field("app_version", .string, .ungrouped)
            .field("start_date", .timestamp)
    }

    private func writeSessions(_ sessions: [(String?, String)]) async throws {
        for (index, (channel, version)) in sessions.enumerated() {
            var values: [String: RecordValue] = ["app_version": .string(version), "start_date": .date(noon)]
            values["channel"] = channel.map(RecordValue.string)
            try await store.write([EntityWrite(values: values, uuid: "s-\(index)")], entity: "session")
        }
    }
}
