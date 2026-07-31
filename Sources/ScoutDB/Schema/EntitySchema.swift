//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// What an entity looks like right now: the fields a write may carry and the
/// rules each one is held to.
///
/// This is the read-only face of a published definition, holding what a caller
/// can act on rather than how the entity is stored — slots, versions and the
/// windows closed fields live in stay inside the library. Declaring a schema
/// goes through `EntityStore.schema(_:)`; this only reads one back.
///
public struct EntitySchema: Sendable, Equatable {
    /// The record type this schema describes.
    public let entity: String

    /// The fields a write may carry, closed ones left out.
    public let fields: [Field]

    /// The fields whose values derive a record's id, turning writes into
    /// upserts.
    public let unique: [String]?

    /// The field tuples no two live records may repeat.
    public let uniqueKeys: [[String]]

    /// One field of an entity, as a caller writing records sees it.
    public struct Field: Sendable, Equatable {
        /// The name the field carries in a record's values.
        public let name: String

        /// The value type every write to the field must match.
        public let type: FieldType

        /// Whether a write that leaves the field empty is rejected.
        public let required: Bool

        /// Whether the value is sealed under the entity's key before it leaves
        /// the device.
        public let encrypted: Bool

        /// Whether the value lives outside the server-side slots, so filters
        /// over it run on the client.
        public let payload: Bool

        /// The entity whose uuids the field holds, if it is a reference.
        public let references: String?

        /// The closed set of strings every value must come from.
        public let allowed: [String]?

        /// The value a write that omits the field gets instead.
        public let defaultValue: RecordValue?

        /// The inclusive bounds every numeric scalar must stay within.
        public let min: Double?

        /// The inclusive bounds every numeric scalar must stay within.
        public let max: Double?

        /// A whole-string regular expression every value must match.
        public let pattern: String?

        /// The field this one shadows, and what it makes of that value — a
        /// derived field is recomputed on every write rather than supplied.
        public let derived: (source: String, transform: FieldTransform)?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.type == rhs.type && lhs.required == rhs.required && lhs.encrypted == rhs.encrypted
                && lhs.payload == rhs.payload && lhs.references == rhs.references && lhs.allowed == rhs.allowed
                && lhs.defaultValue == rhs.defaultValue && lhs.min == rhs.min && lhs.max == rhs.max
                && lhs.pattern == rhs.pattern && lhs.derived?.source == rhs.derived?.source && lhs.derived?.transform == rhs.derived?.transform
        }
    }
}

extension EntitySchema {
    init(_ definition: EntityDefinition) {
        entity = definition.entity
        fields = definition.fields(at: definition.version).map(Field.init)
        unique = definition.unique
        uniqueKeys = definition.claimedKeys
    }
}

extension EntitySchema.Field {
    init(_ field: FieldDefinition) {
        name = field.name
        type = field.type
        required = field.required == true
        encrypted = field.encrypted == true
        payload = field.storage == .payload
        references = field.references
        allowed = field.allowed
        defaultValue = field.defaultValue
        min = field.min
        max = field.max
        pattern = field.pattern
        derived = field.derived.map { ($0.source, $0.transform) }
    }
}
