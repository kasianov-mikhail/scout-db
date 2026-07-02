//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
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
}

func makeDefinition(
    entity: String = "purchase", version: Int = 2, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil,
    views: [AggregateView]? = nil, keyID: String? = nil, ttl: Double? = nil
) -> EntityDefinition {
    EntityDefinition(entity: entity, version: version, fields: fields, envelopeDate: envelopeDate, unique: unique, views: views, keyID: keyID, ttl: ttl)
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
