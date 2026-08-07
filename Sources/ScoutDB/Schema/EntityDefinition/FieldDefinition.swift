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

    /// The record's payload blob: outside the pools, and outside the server's
    /// reach — every filter over it runs client-side.
    case payload
}

extension Storage: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)

        if raw == "payload" {
            self = .payload
            return
        }

        let prefix = raw.firstIndex(of: "_").map { String(raw[..<$0]) }

        guard let pool = FieldType.allCases.first(where: { $0.slotPrefix == prefix }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown storage '\(raw)'")
            )
        }
        self = .slot(pool, raw)
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
