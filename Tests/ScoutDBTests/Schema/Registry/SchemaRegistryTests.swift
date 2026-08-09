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
        let name = SchemaDescriptorEntry.recordID(for: "purchase").recordName
        let record = try #require(await database.records.first { $0.recordID.recordName == name })

        #expect(record.recordType == "Entity")
        #expect(record[Envelope.entity] as? String == SchemaDescriptorEntry.namespace)
        #expect(record[Envelope.uuid] as? String == name)
        #expect(record[Envelope.version] as? Int64 == 1)
        #expect(record["b_00"] is Data)
    }

    @Test("A descriptor is named what CloudKit takes, whatever the entity is called")
    func descriptorNameIsLegal() {
        let entities = ["purchase", "__schema", "order line", "Ünïcøde", String(repeating: "e", count: 400)]

        for entity in entities {
            let id = SchemaDescriptorEntry.recordID(for: entity)
            #expect(id.isLegalRecordName, "\(entity) is filed under \(id.recordName)")
        }

        #expect(Set(entities.map { SchemaDescriptorEntry.recordID(for: $0) }).count == entities.count)
    }

    @Test("A published version overwrites the one before it")
    func onePerEntity() async throws {
        _ = try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .double)
            .field("status", .string)
            .update()

        let descriptors = await database.records.filter {
            $0[Envelope.entity] as? String == SchemaDescriptorEntry.namespace
        }
        #expect(descriptors.map(\.recordID) == [SchemaDescriptorEntry.recordID(for: "purchase")])
        #expect(descriptors.first?[Envelope.version] as? Int64 == 2)

        let definition = try await SchemaRegistry(database: database).definition(for: "purchase")
        #expect(definition.version == 2, "A registry with no cache reads the descriptor by name")
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
