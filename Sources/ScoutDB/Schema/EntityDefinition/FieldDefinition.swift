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

    var isGroupable: Bool {
        guard ungrouped != true else {
            return false
        }
        switch type {
        case .string, .reference, .int, .double:
            return true
        default:
            return false
        }
    }
}

enum Storage: Equatable, Sendable {
    /// A named slot of the given pool: filterable and sortable server-side,
    /// and limited to the pool's capacity.
    case slot(FieldType, String)

    /// A named slot of the payload pool, holding the value as a blob: outside
    /// the typed pools, and outside the server's reach — every filter over it
    /// runs client-side.
    case payload(String)
}

extension Storage {
    /// The record field the value lives in, whichever pool named it.
    var slot: String {
        switch self {
        case .slot(_, let slot), .payload(let slot):
            slot
        }
    }

    /// Whether the field draws from the payload pool rather than a typed one.
    var isPayload: Bool {
        if case .payload = self { true } else { false }
    }
}

extension Storage: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if PayloadPool.slotIndex(raw) != nil {
            self = .payload(raw)
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
        try container.encode(slot)
    }
}
