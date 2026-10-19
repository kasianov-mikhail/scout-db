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

    func isActive(version: Int) -> Bool {
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
    case slot(FieldType, String)
    case payload(String)
}

extension Storage {
    var slot: String {
        switch self {
        case .slot(_, let slot), .payload(let slot):
            slot
        }
    }

    var isPayload: Bool {
        if case .payload = self { true } else { false }
    }
}

extension Storage: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)

        if PayloadPool.slotIndex(slot: raw) != nil {
            self = .payload(raw)
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
        try container.encode(slot)
    }
}
