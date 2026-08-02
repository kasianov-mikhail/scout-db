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
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.slotTypeMismatch(field: "count", type: .int, pool: .string))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects a slot with a foreign prefix")
    func wrongPrefix() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.int, "d_00"))
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.slotOutsidePool("d_00", pool: .int))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects overlapping fields sharing a slot")
    func slotConflict() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "first", type: .int, storage: .slot(.int, "i_00")),
            FieldDefinition(name: "second", type: .int, storage: .slot(.int, "i_00")),
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.sharedSlot("first", "second", slot: "i_00"))) {
            try definition.validate()
        }
    }

    @Test("Validation allows slot reuse across disjoint versions")
    func slotHandover() throws {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "first", type: .int, storage: .slot(.int, "i_00"), until: 2),
            FieldDefinition(name: "second", type: .int, storage: .slot(.int, "i_00"), since: 2),
        ]
        )
        try definition.validate()
    }

    @Test("Validation accepts a text field in the searchable pool")
    func textSlot() throws {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "title", type: .text, storage: .slot(.text, "x_00"))
        ]
        )
        try definition.validate()
    }

    @Test("Validation rejects a text field in the plain string pool")
    func textInPlainPool() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "title", type: .text, storage: .slot(.string, "s_00"))
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.slotTypeMismatch(field: "title", type: .text, pool: .string))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects a slot beyond the pool capacity")
    func slotBeyondCapacity() {
        let definition = makeDefinition(fields: [
            FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_99"))
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.slotBeyondCapacity("s_99", pool: .string))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects a aggregate summing a non-numeric field")
    func sumType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ],
            aggregates: [AggregateDefinition(name: "total", sum: "name")]
        )
        #expect(throws: SchemaError.invalidDefinition(.nonNumericMetric(aggregate: "total", field: "name"))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects a unique key that is not a field")
    func unknownUniqueKey() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
            ],
            unique: ["user_id"]
        )
        #expect(throws: SchemaError.invalidDefinition(.unknownUniqueKey("user_id"))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects an allowed domain on a non-string field")
    func allowedWrongType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), allowed: ["1", "2"])
            ]
        )
        #expect(throws: SchemaError.invalidDefinition(.unsupportedAllowed(field: "count", type: .int))) {
            try definition.validate()
        }
    }

    @Test("Validation rejects a numeric bound on a non-numeric field")
    func boundWrongType() {
        let definition = makeDefinition(
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"), min: 0)
            ]
        )
        #expect(throws: SchemaError.invalidDefinition(.unsupportedBounds(field: "name", type: .string))) {
            try definition.validate()
        }
    }
}

func makeDefinition(
    entity: String = "purchase", version: Int = 2, fields: [FieldDefinition], unique: [String]? = nil,
    aggregates: [AggregateDefinition]? = nil
) -> EntityDefinition {
    EntityDefinition(entity: entity, version: version, fields: fields, unique: unique, aggregates: aggregates)
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
        ]
    )
}
