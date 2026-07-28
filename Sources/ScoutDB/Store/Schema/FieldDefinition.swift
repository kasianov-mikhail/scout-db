//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One field of an entity, as published in its definition.
///
/// A field is never edited in place: retyping or moving it closes the old
/// declaration at a version and opens a new one, so `EntityDefinition.fields`
/// holds every declaration the entity has ever had and `since`/`until` say
/// which versions each one covers.
///
public struct FieldDefinition: Codable, Equatable, Sendable {
    /// The name the field carries in a record's values, unique among the
    /// fields active at any one version.
    public let name: String

    /// The value type every write to the field must match.
    public let type: FieldType

    /// Where the value lives: a slot of its pool, which the server can filter
    /// and sort on, or the record's payload blob, which it cannot.
    public let storage: Storage

    /// The first version carrying the field; `nil` reads as version 1.
    public var since: Int?

    /// The first version no longer carrying the field; `nil` means it is still
    /// active.
    public var until: Int?

    /// Rejects a write that leaves the field without a value, once defaults
    /// and derivations have been applied.
    public var required: Bool?

    /// The value a write that omits the field gets instead.
    public var defaultValue: RecordValue?

    /// The closed set of strings every value of the field must come from.
    public var allowed: [String]?

    /// The inclusive lower bound every numeric scalar of the field must clear.
    public var minimum: Double?

    /// The inclusive upper bound every numeric scalar of the field must stay
    /// under.
    public var maximum: Double?

    /// Makes the field a shadow of another one, recomputed from its source on
    /// every write rather than supplied by the caller.
    public var derived: Derivation?

    /// Seals the value under the definition's `keyID` before it leaves the
    /// device; only a payload field can be encrypted.
    public var encrypted: Bool?

    /// The entity whose uuids this field holds, making it a reference that
    /// `join`, `children` and the reference checks can follow.
    public var references: String?

    /// Restricts a scalar reference to one holder per parent, claim-backed the
    /// way `EntityDefinition.enforcedKeys` are.
    public var exclusive: Bool?

    /// A whole-string regular expression every value of the field must match.
    public var pattern: String?

    public init(
        name: String, type: FieldType, storage: Storage, since: Int? = nil, until: Int? = nil, required: Bool? = nil, defaultValue: RecordValue? = nil,
        allowed: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil, derived: Derivation? = nil, encrypted: Bool? = nil, references: String? = nil,
        exclusive: Bool? = nil, pattern: String? = nil
    ) {
        self.name = name
        self.type = type
        self.storage = storage
        self.since = since
        self.until = until
        self.required = required
        self.defaultValue = defaultValue
        self.allowed = allowed
        self.minimum = minimum
        self.maximum = maximum
        self.derived = derived
        self.encrypted = encrypted
        self.references = references
        self.exclusive = exclusive
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, storage, since, until, required, allowed, minimum, maximum, derived, encrypted, references, exclusive, pattern
        case defaultValue = "default"
    }

    /// Whether the given version carries the field, `since` inclusive and
    /// `until` exclusive.
    public func isActive(at version: Int) -> Bool {
        version >= (since ?? 1) && version < (until ?? .max)
    }

    var alwaysPresent: Bool {
        required == true || defaultValue != nil
    }

    func overlaps(_ other: FieldDefinition) -> Bool {
        (since ?? 1) < (other.until ?? .max) && (other.since ?? 1) < (until ?? .max)
    }
}

/// How a derived field is recomputed: which field it reads, and what it makes
/// of that value.
public struct Derivation: Codable, Equatable, Sendable {
    /// The field being shadowed, itself a field of the same entity.
    public let source: String

    /// What the source value is turned into.
    public let transform: Transform

    public init(source: String, transform: Transform) {
        self.source = source
        self.transform = transform
    }

    /// The transforms a derived field can apply to its source.
    ///
    /// `lowercase` and `fold` serve normalized comparisons, `reversed` turns
    /// an `endsWith` into a server-side `beginsWith`, `ngrams` narrows
    /// `contains` and `like` before the exact client check, `hour`, `day`,
    /// `week` and `month` truncate a timestamp to group by it, and `hmac`
    /// keeps an encrypted field filterable through a keyed digest.
    ///
    public enum Transform: String, Codable, Sendable {
        case lowercase, fold, reversed, ngrams, hour, day, week, month, hmac
    }
}

/// Where a field's value is written in the underlying record.
public enum Storage: Equatable, Sendable {
    /// A named slot of the given pool: filterable and sortable server-side,
    /// and limited to the pool's capacity.
    case slot(Pool, String)

    /// The record's payload blob: outside the pools, and outside the server's
    /// reach — every filter over it runs client-side.
    case payload
}

extension Storage: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "payload" {
            self = .payload
        } else if let pool = Pool.pool(forSlot: raw) {
            self = .slot(pool, raw)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown storage '\(raw)'"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .payload:
            try container.encode("payload")
        case .slot(_, let slot):
            try container.encode(slot)
        }
    }
}
