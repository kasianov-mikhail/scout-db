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
            .field("product_id", .string, .required, .references("product"))
            .field("status", .string, .allowed(["placed", "paid"]), .defaultValue(.string("placed")))
            .field("quantity", .int, .min(1), .max(20))
            .field("email", .string, .matches("^.+@.+$"))
            .field("email_lower", .string, .derived(from: "email", .lowercase))
            .field("comment", .string, .payload)
            .field("date", .timestamp)
            .unique(on: "product_id", "date")
            .uniqueKey(on: "email")
            .create()
    }

    @Test("A field carries every rule the builder declared")
    func fieldRules() async throws {
        let schema = try await registry.schema(for: "purchase")
        let byName = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0) })

        let product = try #require(byName["product_id"])
        #expect(product.type == .string)
        #expect(product.required)
        #expect(product.references == "product")

        let status = try #require(byName["status"])
        #expect(status.allowed == ["placed", "paid"])
        #expect(status.defaultValue == .string("placed"))

        let quantity = try #require(byName["quantity"])
        #expect(quantity.min == 1)
        #expect(quantity.max == 20)

        #expect(try #require(byName["email"]).pattern == "^.+@.+$")
        #expect(try #require(byName["email_lower"]).derived?.transform == .lowercase)
        #expect(try #require(byName["email_lower"]).derived?.source == "email")
        #expect(try #require(byName["comment"]).payload)
        #expect(try #require(byName["date"]).payload == false)
    }

    @Test("Entity-wide settings come across")
    func entitySettings() async throws {
        let schema = try await registry.schema(for: "purchase")
        #expect(schema.entity == "purchase")
        #expect(schema.unique == ["product_id", "date"])
        #expect(schema.uniqueKeys == [["email"]])
    }

    @Test("An encrypted field reads back as sealed")
    func encryptedField() async throws {
        try await store.schema("secret")
            .field("token", .string, .payload, .encrypted)
            .keyID("k1")
            .create()

        let schema = try await registry.schema(for: "secret")
        #expect(try #require(schema.fields.first).encrypted)
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

    @Test("Loaded entities list themselves")
    func loadedSchemas() async throws {
        let reader = SchemaRegistry(database: database)
        #expect(await reader.schemas().isEmpty)
        try await reader.preload()
        #expect(await reader.schemas().map(\.entity) == ["purchase"])
    }
}
