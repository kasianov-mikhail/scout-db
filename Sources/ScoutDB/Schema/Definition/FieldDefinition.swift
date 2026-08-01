//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct FieldDefinition: Codable, Equatable, Sendable {
    let name: String

    let type: FieldType

    let storage: Storage

    var since: Int?

    var until: Int?

    var required: Bool?

    var defaultValue: RecordValue?

    var allowed: [String]?

    var min: Double?

    var max: Double?

    var pattern: String?

    var ungrouped: Bool?

    init(
        name: String, type: FieldType, storage: Storage, since: Int? = nil, until: Int? = nil, required: Bool? = nil,
        defaultValue: RecordValue? = nil, allowed: [String]? = nil, min: Double? = nil, max: Double? = nil,
        pattern: String? = nil, ungrouped: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.storage = storage
        self.since = since
        self.until = until
        self.required = required
        self.defaultValue = defaultValue
        self.allowed = allowed
        self.min = min
        self.max = max
        self.pattern = pattern
        self.ungrouped = ungrouped
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, storage, since, until, required, allowed, pattern, ungrouped
        case min = "minimum"
        case max = "maximum"
        case defaultValue = "default"
    }

    func isActive(at version: Int) -> Bool {
        version >= (since ?? 1) && version < (until ?? .max)
    }

    var alwaysPresent: Bool {
        required == true || defaultValue != nil
    }

    func overlaps(_ other: FieldDefinition) -> Bool {
        (since ?? 1) < (other.until ?? .max) && (other.since ?? 1) < (until ?? .max)
    }
}

enum Storage: Equatable, Sendable {
    /// A named slot of the given pool: filterable and sortable server-side,
    /// and limited to the pool's capacity.
    case slot(FieldType, String)

    /// The record's payload blob: outside the pools, and outside the server's
    /// reach — every filter over it runs client-side.
    case payload
}

extension Storage: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "payload" {
            self = .payload
        } else if let pool = FieldType.type(forSlot: raw) {
            self = .slot(pool, raw)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown storage '\(raw)'")
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .payload:
            try container.encode("payload")
        case .slot(_, let slot):
            try container.encode(slot)
        }
    }
}
