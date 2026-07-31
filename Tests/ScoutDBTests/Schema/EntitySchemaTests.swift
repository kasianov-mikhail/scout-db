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
        #expect(schema.audited == false)
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
        #expect(await reader.schemas().contains { $0.entity.hasPrefix("_") } == false)
    }

    @Test("An audited entity records history without any setup of its own")
    func revisionsNeedNoSetup() async throws {
        try await store.schema("note")
            .field("body", .string, .required)
            .field("date", .timestamp)
            .audited()
            .create()

        try await store.write(["body": .string("first"), "date": .date(Date())], entity: "note", uuid: "n-1")
        try await store.update(entity: "note", uuid: "n-1") { $0.values["body"] = .string("second") }

        let history = try await store.history(entity: "note", uuid: "n-1")
        #expect(history.map { $0.values["body"] } == [.string("first")])
        #expect(try await registry.schema(for: "note").audited)
    }

    @Test("A transaction commits without any setup of its own")
    func transactionsNeedNoSetup() async throws {
        try await store.schema("note")
            .field("body", .string, .required)
            .field("date", .timestamp)
            .create()

        try await store.transaction { draft in
            draft.write(["body": .string("first"), "date": .date(Date())], entity: "note", uuid: "n-1")
        }
        #expect(try await store.fetch(entity: "note", uuids: ["n-1"]).count == 1)
    }
}
