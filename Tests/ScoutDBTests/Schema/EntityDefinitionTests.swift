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

@Suite("EntityDefinition")
struct EntityDefinitionTests {
    @Test("Storage coding round-trips slots and payload")
    func storageCoding() throws {
        let definition = makePurchaseDefinition()
        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(EntityDefinition.self, from: data)
        #expect(decoded == definition)
    }

    @Test("Storage decodes from a bare slot name")
    func storageDecoding() throws {
        let json = Data(#""s_03""#.utf8)
        let storage = try JSONDecoder().decode(Storage.self, from: json)
        #expect(storage == .slot(.string, "s_03"))
    }

    @Test("Fields are filtered by since and until")
    func fieldActivity() {
        let definition = makePurchaseDefinition()
        #expect(definition.fields(at: 1).map(\.name) == ["product_id", "date", "amount", "comment"])
        #expect(definition.fields(at: 2).map(\.name) == ["product_id", "date", "quantity", "total", "comment"])
    }

    @Test("Validation rejects a slot in the wrong pool")
    func wrongPool() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.string, "s_00"))
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects a slot with a foreign prefix")
    func wrongPrefix() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.int, "d_00"))
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects overlapping fields sharing a slot")
    func slotConflict() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "first", type: .int, storage: .slot(.int, "i_00")),
            FieldDefinition(name: "second", type: .int, storage: .slot(.int, "i_00")),
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation allows slot reuse across disjoint versions")
    func slotHandover() throws {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "first", type: .int, storage: .slot(.int, "i_00"), until: 2),
            FieldDefinition(name: "second", type: .int, storage: .slot(.int, "i_00"), since: 2),
        ])
        try definition.validate()
    }

    @Test("Validation rejects an envelope date inactive at the current version")
    func envelopeDateClosedAtVersion() {
        let definition = makeDefinition(
            entity: "e", version: 2,
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), until: 2),
            ], envelopeDate: "date")
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation accepts an envelope date active at the current version")
    func envelopeDateActiveAtVersion() throws {
        let definition = makeDefinition(
            entity: "e", version: 2,
            fields: [FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), since: 1)],
            envelopeDate: "date")
        try definition.validate()
    }

    @Test("Validation accepts a text field in the searchable pool")
    func textSlot() throws {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "title", type: .text, storage: .slot(.text, "x_00"))
        ])
        try definition.validate()
    }

    @Test("Validation rejects a text field in the plain string pool")
    func textInPlainPool() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "title", type: .text, storage: .slot(.string, "s_00"))
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects an encrypted field in a slot")
    func encryptedSlot() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_00"), encrypted: true)
            ], keyID: "k1")
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects encryption without a keyID")
    func encryptedWithoutKey() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "email", type: .string, storage: .payload, encrypted: true)
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation accepts string and string-list references, rejects other types")
    func referenceTypes() throws {
        try makeDefinition(fields: [
            FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_00"), references: "author")
        ]).validate()
        try makeDefinition(fields: [
            FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author")
        ]).validate()
        let scalar = makeDefinition(fields: [
            FieldDefinition(name: "author_no", type: .int, storage: .slot(.int, "i_00"), references: "author")
        ])
        #expect(throws: SchemaError.self) { try scalar.validate() }
        let list = makeDefinition(fields: [
            FieldDefinition(name: "author_nos", type: .intList, storage: .slot(.intList, "li_00"), references: "author")
        ])
        #expect(throws: SchemaError.self) { try list.validate() }
    }

    @Test("Validation restricts exclusive to scalar string references")
    func exclusiveReferenceTypes() throws {
        try makeDefinition(fields: [
            FieldDefinition(name: "person_id", type: .string, storage: .slot(.string, "s_00"), references: "person", exclusive: true)
        ]).validate()
        let unreferenced = makeDefinition(fields: [
            FieldDefinition(name: "person_id", type: .string, storage: .slot(.string, "s_00"), exclusive: true)
        ])
        #expect(throws: SchemaError.self) { try unreferenced.validate() }
        let list = makeDefinition(fields: [
            FieldDefinition(name: "person_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "person", exclusive: true)
        ])
        #expect(throws: SchemaError.self) { try list.validate() }
    }

    @Test("Validation rejects a non-timestamp envelope date")
    func envelopeDateType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
            ], envelopeDate: "name")
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects a view without an envelope date")
    func viewWithoutDate() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
            ], views: [AggregateView(name: "hourly")])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects a slot beyond the pool capacity")
    func slotBeyondCapacity() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_99"))
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects an asset field in payload")
    func assetStorage() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "screenshot", type: .asset, storage: .payload)
        ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation allows several asset fields in distinct slots")
    func assetPool() throws {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "screenshot", type: .asset, storage: .slot(.asset, "a_00")),
            FieldDefinition(name: "dump", type: .asset, storage: .slot(.asset, "a_01")),
        ])
        try definition.validate()
    }

    @Test("Validation rejects a view summing a non-numeric field")
    func sumType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ], envelopeDate: "date", views: [AggregateView(name: "hourly", sum: "name")])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects a unique key that is not a field")
    func unknownUniqueKey() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
            ], unique: ["user_id"])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects an allowed domain on a non-string field")
    func allowedWrongType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), allowed: ["1", "2"])
            ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("Validation rejects a numeric bound on a non-numeric field")
    func boundWrongType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"), minimum: 0)
            ])
        #expect(throws: SchemaError.self) { try definition.validate() }
    }

    @Test("A unique key needs no slot-backed field, since its claims are reached by name")
    func slotlessUniqueKey() async throws {
        var definition = EntityDefinition(
            entity: "note", version: 1,
            fields: [FieldDefinition(name: "body", type: .string, storage: .payload)])
        definition.uniqueKeys = [["body"]]
        try definition.validate()
        try definition.validateForPublish()

        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(definition)
        #expect(try await registry.definition(for: "note").uniqueKeys == [["body"]])

        let store = EntityStore(database: database, registry: registry)
        try await store.write(["body": .string("first")], entity: "note", uuid: "n-1")
        await #expect(throws: SchemaError.duplicateKey(fields: ["body"])) {
            try await store.write(["body": .string("first")], entity: "note", uuid: "n-2")
        }
    }

    @Test("A definition that published enforcedKeys keeps them, and folds them in on update")
    func legacyEnforcedKeys() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        let definition = EntityDefinition(
            entity: "badge", version: 1,
            fields: [FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00"))],
            enforcedKeys: [["code"]])
        try await registry.publish(definition)

        let store = EntityStore(database: database, registry: registry)
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        }

        try await store.schema("badge").field("code", .string).field("label", .string).update()
        let next = try await registry.definition(for: "badge")
        #expect(next.uniqueKeys == [["code"]])
        #expect(next.enforcedKeys == nil)
    }
}

func makeDefinition(
    entity: String = "purchase", version: Int = 2, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil,
    views: [AggregateView]? = nil, keyID: String? = nil, ttl: Double? = nil
) -> EntityDefinition {
    EntityDefinition(entity: entity, version: version, fields: fields, envelopeDate: envelopeDate, unique: unique, views: views, keyID: keyID, ttl: ttl)
}

func makeSeatDefinition() -> EntityDefinition {
    EntityDefinition(
        entity: "seat", version: 1,
        fields: [
            FieldDefinition(name: "row", type: .string, storage: .slot(.string, "s_00")),
            FieldDefinition(name: "number", type: .int, storage: .slot(.int, "i_00")),
            FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_01")),
        ],
        uniqueKeys: [["row", "number"]])
}

func makePurchaseDefinition() -> EntityDefinition {
    makeDefinition(
        fields: [
            FieldDefinition(name: "product_id", type: .string, storage: .slot(.string, "s_00")),
            FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            FieldDefinition(name: "amount", type: .int, storage: .slot(.int, "i_00"), until: 2),
            FieldDefinition(name: "quantity", type: .int, storage: .slot(.int, "i_01"), since: 2),
            FieldDefinition(name: "total", type: .double, storage: .slot(.double, "d_00"), since: 2),
            FieldDefinition(name: "comment", type: .string, storage: .payload),
        ], envelopeDate: "date")
}
