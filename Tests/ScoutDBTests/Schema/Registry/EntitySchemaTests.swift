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

@Suite("Schema, as callers read it")
struct EntitySchemaTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("status", .string, .allowed(["placed", "paid"]), .defaultValue(.string("placed")))
            .field("quantity", .int, .min(1), .max(20))
            .field("email", .string, .matches("^.+@.+$"))
            .field("comment", .string, .payload)
            .field("date", .timestamp)
            .create()
    }

    @Test("A field carries every rule the builder declared")
    func fieldRules() async throws {
        let schema = try await registry.schema(for: "purchase")
        let byName = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0) })

        #expect(schema.entity == "purchase")

        let product = try #require(byName["product_id"])
        #expect(product.type == .string)
        #expect(product.required)

        let status = try #require(byName["status"])
        #expect(status.allowed == ["placed", "paid"])
        #expect(status.defaultValue == .string("placed"))

        let quantity = try #require(byName["quantity"])
        #expect(quantity.min == 1)
        #expect(quantity.max == 20)

        #expect(try #require(byName["email"]).pattern == "^.+@.+$")
        #expect(try #require(byName["comment"]).payload)
        #expect(try #require(byName["date"]).payload == false)
    }

    @Test("A closed field leaves the schema")
    func closedFieldDropsOut() async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("date", .timestamp)
            .update()

        let schema = try await registry.schema(for: "purchase")
        #expect(schema.fields.map(\.name).sorted() == ["date", "product_id"])
    }

    @Test("An aggregate carries the shape the builder declared")
    func aggregateShapes() async throws {
        try await store.schema("visit")
            .field("page", .string, .ungrouped)
            .field("seen_at", .timestamp)
            .field("load", .double, .ungrouped)
            .count(by: "page", at: "seen_at", parts: 4)
            .sum("load", by: "page", at: "seen_at", shards: 2)
            .histogram(of: "load", bounds: [10, 100])
            .create()

        let schema = try await registry.schema(for: "visit")

        #expect(
            schema.aggregates == [
                EntitySchema.Aggregate(
                    group: "page",
                    date: "seen_at",
                    field: nil,
                    metric: nil,
                    bounds: nil,
                    shards: nil,
                    parts: 4
                ),
                EntitySchema.Aggregate(
                    group: "page",
                    date: "seen_at",
                    field: "load",
                    metric: .sum,
                    bounds: nil,
                    shards: 2,
                    parts: nil
                ),
                EntitySchema.Aggregate(
                    group: nil,
                    date: nil,
                    field: "load",
                    metric: nil,
                    bounds: [10, 100],
                    shards: nil,
                    parts: nil
                ),
            ]
        )
    }

    @Test("An update that only adds an aggregate shows it, with the fields unchanged")
    func addedAggregateShows() async throws {
        let before = try await registry.schema(for: "purchase")

        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("status", .string, .allowed(["placed", "paid"]), .defaultValue(.string("placed")))
            .field("quantity", .int, .min(1), .max(20))
            .field("email", .string, .matches("^.+@.+$"))
            .field("comment", .string, .payload)
            .field("date", .timestamp)
            .count(by: "product_id", at: "date", parts: 8)
            .update()

        let after = try await registry.schema(for: "purchase")

        #expect(after.fields == before.fields)
        #expect(after.aggregates.contains { $0.group == "product_id" && $0.date == "date" && $0.parts == 8 })
        #expect(after.aggregates.count == before.aggregates.count + 1)
    }

    @Test("A closed field takes its aggregates out of the schema")
    func lapsedAggregateDropsOut() async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("date", .timestamp)
            .update()

        let schema = try await registry.schema(for: "purchase")
        let used = Set(schema.aggregates.compactMap(\.group) + schema.aggregates.compactMap(\.field))

        #expect(used.isSubset(of: ["product_id", "date"]))
    }
}
