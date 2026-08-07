//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    /// What a field is held to beyond its type.
    ///
    /// Constraints are checked on the device before a write leaves it, so a
    /// rejected value costs nothing and never reaches CloudKit. Several may sit
    /// on one field: `.required` with `.allowed`, `.min` with `.max`.
    ///
    /// ```swift
    /// .field("status", .string, .required, .allowed(["placed", "paid"]))
    /// .field("quantity", .int, .min(1), .max(20))
    /// ```
    ///
    public enum FieldConstraint: Sendable {
        /// Rejects a write that leaves the field without a value, once the
        /// default has been applied.
        case required

        /// Keeps the field out of the typed pools, in a payload slot of its
        /// own: sixteen of those exist per entity, and a value in one lies
        /// beyond the server's filters and sorts.
        case payload

        /// The closed set of strings every value of the field must come from.
        case allowed([String])

        /// The value a write that omits the field gets instead.
        case defaultValue(RecordValue)

        /// The inclusive lower bound every numeric scalar must clear.
        ///
        /// A bound describes the records the entity holds, not only the next
        /// write: ``QueryBuilder/count()`` reads `min` and `max` as the whole
        /// domain of an integer field an aggregate groups by. So a version may
        /// widen it or drop it, and ``SchemaBuilder/update()`` refuses to narrow
        /// it over records already written outside the narrower range.
        case min(Double)

        /// The inclusive upper bound every numeric scalar must stay under,
        /// widenable across versions but not narrowable as in ``min(_:)``.
        case max(Double)

        /// A regular expression every value of the field must match whole.
        case matches(String)

        /// Keeps the field out of the vectors a creation builds: nothing counts by
        /// it, and no write pays for its cells. For the fields of many distinct
        /// values — a uuid, a free-form string — that no read groups by.
        case ungrouped
    }
}

extension SchemaBuilder.FieldConstraint {
    func apply(to field: inout FieldDefinition) {
        switch self {
        case .required:
            field.required = true
        case .payload:
            break
        case .allowed(let values):
            field.allowed = values
        case .defaultValue(let value):
            field.defaultValue = value
        case .min(let value):
            field.min = value
        case .max(let value):
            field.max = value
        case .matches(let pattern):
            field.pattern = pattern
        case .ungrouped:
            field.ungrouped = true
        }
    }
}
