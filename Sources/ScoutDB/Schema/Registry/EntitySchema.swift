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
