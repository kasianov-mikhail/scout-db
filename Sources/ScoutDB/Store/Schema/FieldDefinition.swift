//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct FieldDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let type: FieldType
    public let storage: Storage
    public var since: Int?
    public var until: Int?
    public var required: Bool?
    public var defaultValue: RecordValue?
    public var allowed: [String]?
    public var minimum: Double?
    public var maximum: Double?
    public var derived: Derivation?
    public var encrypted: Bool?
    public var references: String?
    public var exclusive: Bool?

    public init(
        name: String, type: FieldType, storage: Storage, since: Int? = nil, until: Int? = nil, required: Bool? = nil, defaultValue: RecordValue? = nil,
        allowed: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil, derived: Derivation? = nil, encrypted: Bool? = nil, references: String? = nil,
        exclusive: Bool? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, storage, since, until, required, allowed, minimum, maximum, derived, encrypted, references, exclusive
        case defaultValue = "default"
    }

    public func isActive(at version: Int) -> Bool {
        version >= (since ?? 1) && version < (until ?? .max)
    }

    func overlaps(_ other: FieldDefinition) -> Bool {
        (since ?? 1) < (other.until ?? .max) && (other.since ?? 1) < (until ?? .max)
    }
}

public struct Derivation: Codable, Equatable, Sendable {
    public let source: String
    public let transform: Transform

    public init(source: String, transform: Transform) {
        self.source = source
        self.transform = transform
    }

    public enum Transform: String, Codable, Sendable {
        case lowercase, fold, reversed, ngrams, hour, day, week, month, hmac
    }
}

public enum Storage: Equatable, Sendable {
    case slot(Pool, String)
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
