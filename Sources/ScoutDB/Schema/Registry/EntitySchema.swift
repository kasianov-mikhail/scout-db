//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// What an entity looks like right now: the fields a write may carry, the
/// rules each one is held to, and the aggregates kept over them.
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

    /// The aggregates the entity keeps, lapsed ones left out.
    public let aggregates: [Aggregate]

    /// One field of an entity, as a caller writing records sees it.
    public struct Field: Sendable, Equatable {
        /// The name the field carries in a record's values.
        public let name: String

        /// The value type every write to the field must match.
        public let type: FieldType

        /// Whether a write that leaves the field empty is rejected.
        public let required: Bool

        /// Whether the value lives in a payload slot rather than a typed one,
        /// so filters over it run on the client.
        public let payload: Bool

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
    }
}

extension EntitySchema {
    /// One aggregate of an entity, in the terms a caller declares it with.
    ///
    /// A caller that publishes its declarations compares these with its own
    /// to decide whether an `update()` is due, since an aggregate can change
    /// while the fields stay the same.
    ///
    public struct Aggregate: Sendable, Equatable {
        /// The field the aggregate groups by, or `nil` for one group over all records.
        public let group: String?

        /// The `.timestamp` field that dates a record, or `nil` for the hour of the write.
        public let date: String?

        /// The field the aggregate folds or buckets, or `nil` for a count.
        public let field: String?

        /// How the field is folded, or `nil` for a count or a histogram.
        public let metric: Metric?

        /// The upper bounds of a histogram's buckets, or `nil` for any other aggregate.
        public let bounds: [Double]?

        /// The shard count the declaration asked for, or `nil` for one record per cell.
        public let shards: Int?

        /// The index parts the declaration asked for, or `nil` for one page per week.
        public let parts: Int?
    }
}

extension EntitySchema {
    init(definition: EntityDefinition) {
        self.init(
            entity: definition.entity,
            fields: definition.activeFields.map(Field.init(field:)),
            aggregates: definition.aggregates.map(Aggregate.init(aggregate:))
        )
    }
}

extension EntitySchema.Field {
    fileprivate init(field: FieldDefinition) {
        self.init(
            name: field.name,
            type: field.type,
            required: field.required == true,
            payload: field.storage.isPayload,
            allowed: field.allowed,
            defaultValue: field.defaultValue,
            min: field.min,
            max: field.max,
            pattern: field.pattern
        )
    }
}

extension EntitySchema.Aggregate {
    fileprivate init(aggregate: AggregateDefinition) {
        self.init(
            group: aggregate.groupBy,
            date: aggregate.date,
            field: aggregate.measure?.field ?? aggregate.measure?.histogram?.field,
            metric: aggregate.measure?.metric,
            bounds: aggregate.measure?.histogram?.bounds,
            shards: aggregate.shards,
            parts: aggregate.parts
        )
    }
}
