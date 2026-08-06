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

@Suite("Registry records, filed among the entities")
struct SchemaRegistryTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .double)
            .create()
    }

    @Test("A descriptor is an Entity record under the reserved namespace")
    func descriptorShape() async throws {
        let record = try #require(await database.records.first { $0.recordID.recordName == "purchase@1" })

        #expect(record.recordType == "Entity")
        #expect(record[Envelope.entity] as? String == SchemaDescriptorEntry.namespace)
        #expect(record["s_01"] as? String == "purchase")
        #expect(record["s_02"] as? String == "active")
        #expect(record[Envelope.version] as? Int64 == 1)
        #expect(record["b_00"] is Data)
    }

    @Test("A published schema reads back through the registry")
    func roundTrip() async throws {
        let definition = try await registry.definition(for: "purchase")

        #expect(definition.version == 1)
        #expect(definition.fields.map(\.name) == ["product_id", "amount"])
    }

    @Test("A scan of the entity never reaches the descriptors")
    func descriptorsStayOutOfScans() async throws {
        try await store.write(
            [EntityWrite(values: ["product_id": .string("sku-1"), "amount": .double(9.99)], uuid: "p-1")],
            entity: "purchase"
        )

        let records = try await store.query("purchase").take(100)
        #expect(records.map(\.uuid) == ["p-1"])
        #expect(try await store.query("purchase").count() == 1)
    }

    @Test("The reserved namespace is not a name a caller may declare")
    func reservedNamespace() async throws {
        await #expect(throws: SchemaError.invalidDefinition(.reservedEntity(SchemaDescriptorEntry.namespace))) {
            try await store.schema(SchemaDescriptorEntry.namespace)
                .field("product_id", .string)
                .create()
        }
    }
}
