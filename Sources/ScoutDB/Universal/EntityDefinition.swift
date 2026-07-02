//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct EntityDefinition: Codable, Equatable, Sendable {
    let entity: String
    let version: Int
    let fields: [FieldDefinition]
    var envelopeDate: String?
    var unique: [String]?
    var views: [AggregateView]?
    var keyID: String?
    var ttl: Double?

    func fields(at version: Int) -> [FieldDefinition] {
        fields.filter { $0.isActive(at: version) }
    }

    func validate() throws {
        let names = Set(fields.map(\.name))
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                guard field.type.pool == pool else {
                    throw UniversalSchemaError.invalidDefinition(
                        "Field '\(field.name)' of type '\(field.type.rawValue)' cannot live in the '\(pool.rawValue)' pool")
                }
                guard slot.hasPrefix("\(pool.rawValue)_"), let index = Int(slot.dropFirst(pool.rawValue.count + 1)), index >= 0 else {
                    throw UniversalSchemaError.invalidDefinition("Slot '\(slot)' does not belong to the '\(pool.rawValue)' pool")
                }
                guard index < pool.capacity else {
                    throw UniversalSchemaError.invalidDefinition("Slot '\(slot)' is beyond the '\(pool.rawValue)' pool capacity of \(pool.capacity)")
                }
            }
            if field.type == .asset, field.storage == .payload {
                throw UniversalSchemaError.invalidDefinition("Asset field '\(field.name)' must live in an asset slot")
            }
            if let derived = field.derived, !names.contains(derived.source) {
                throw UniversalSchemaError.invalidDefinition("Field '\(field.name)' derives from unknown '\(derived.source)'")
            }
            if field.derived?.transform == .ngrams, field.type != .stringList {
                throw UniversalSchemaError.invalidDefinition("Ngram field '\(field.name)' must be a string list")
            }
            if field.encrypted == true, field.storage != .payload {
                throw UniversalSchemaError.invalidDefinition("Encrypted field '\(field.name)' must live in payload")
            }
            if field.encrypted == true || field.derived?.transform == .hmac, keyID == nil {
                throw UniversalSchemaError.invalidDefinition("Field '\(field.name)' needs a keyID on the definition")
            }
            if field.references != nil, field.type != .string {
                throw UniversalSchemaError.invalidDefinition("Reference field '\(field.name)' must be a string uuid")
            }
        }
        for lhs in fields {
            for rhs in fields where lhs.name != rhs.name || lhs.since != rhs.since {
                guard case .slot(_, let lhsSlot) = lhs.storage else { continue }
                guard case .slot(_, let rhsSlot) = rhs.storage else { continue }
                if lhsSlot == rhsSlot, lhs.overlaps(rhs) {
                    throw UniversalSchemaError.invalidDefinition("Fields '\(lhs.name)' and '\(rhs.name)' share slot '\(lhsSlot)'")
                }
            }
        }
        if let envelopeDate {
            guard fields.first(where: { $0.name == envelopeDate })?.type == .timestamp else {
                throw UniversalSchemaError.invalidDefinition("Envelope date '\(envelopeDate)' is not a timestamp field")
            }
        }
        if ttl != nil, envelopeDate == nil {
            throw UniversalSchemaError.invalidDefinition("TTL requires an envelope date")
        }
        for key in unique ?? [] where !names.contains(key) {
            throw UniversalSchemaError.invalidDefinition("Unique key '\(key)' is not a field")
        }
        for view in views ?? [] {
            guard envelopeDate != nil else {
                throw UniversalSchemaError.invalidDefinition("View '\(view.name)' requires an envelope date")
            }
            if let groupBy = view.groupBy, !names.contains(groupBy) {
                throw UniversalSchemaError.invalidDefinition("View '\(view.name)' groups by unknown '\(groupBy)'")
            }
            let metrics = [view.sum, view.min, view.max, view.stats, view.histogram?.field].compactMap { $0 }
            guard metrics.count <= 1 else {
                throw UniversalSchemaError.invalidDefinition("View '\(view.name)' declares more than one metric")
            }
            for field in metrics {
                guard let type = fields.first(where: { $0.name == field })?.type, type == .int || type == .double else {
                    throw UniversalSchemaError.invalidDefinition("View '\(view.name)' aggregates non-numeric '\(field)'")
                }
            }
            if let histogram = view.histogram {
                guard histogram.bounds.count > 0, histogram.bounds.count < 64, histogram.bounds == histogram.bounds.sorted() else {
                    throw UniversalSchemaError.invalidDefinition("View '\(view.name)' has invalid histogram bounds")
                }
                guard view.bucket == nil else {
                    throw UniversalSchemaError.invalidDefinition("View '\(view.name)' cannot combine a histogram with a time bucket")
                }
            }
        }
    }
}

struct FieldDefinition: Codable, Equatable, Sendable {
    let name: String
    let type: FieldType
    let storage: Storage
    var since: Int?
    var until: Int?
    var required: Bool?
    var defaultValue: RecordValue?
    var allowed: [String]?
    var minimum: Double?
    var maximum: Double?
    var derived: Derivation?
    var encrypted: Bool?
    var references: String?

    private enum CodingKeys: String, CodingKey {
        case name, type, storage, since, until, required, allowed, minimum, maximum, derived, encrypted, references
        case defaultValue = "default"
    }

    func isActive(at version: Int) -> Bool {
        version >= (since ?? 1) && version < (until ?? .max)
    }

    func overlaps(_ other: FieldDefinition) -> Bool {
        (since ?? 1) < (other.until ?? .max) && (other.since ?? 1) < (until ?? .max)
    }
}

struct Derivation: Codable, Equatable, Sendable {
    let source: String
    let transform: Transform

    enum Transform: String, Codable, Sendable {
        case lowercase, fold, reversed, ngrams, hour, day, week, month, hmac
    }
}

struct AggregateView: Codable, Equatable, Sendable {
    let name: String
    var groupBy: String?
    var bucket: Bucket?
    var sum: String?
    var min: String?
    var max: String?
    var stats: String?
    var histogram: Histogram?

    struct Histogram: Codable, Equatable, Sendable {
        let field: String
        let bounds: [Double]
    }

    enum Bucket: String, Codable, Sendable {
        case hour, weekday, day
    }

    enum Metric: Equatable, Sendable {
        case sum, min, max

        func combine(_ lhs: Double, _ rhs: Double) -> Double {
            switch self {
            case .sum: lhs + rhs
            case .min: Swift.min(lhs, rhs)
            case .max: Swift.max(lhs, rhs)
            }
        }
    }

    var metric: (kind: Metric, field: String)? {
        if let sum { return (.sum, sum) }
        if let min { return (.min, min) }
        if let max { return (.max, max) }
        if let stats { return (.sum, stats) }
        return nil
    }
}

enum FieldType: String, Codable, Equatable, Sendable {
    case string, text, int, double, timestamp, bytes, location, reference, asset
    case stringList, intList, doubleList, timestampList, locationList, assetList

    var pool: Pool? {
        switch self {
        case .string: .string
        case .text: .text
        case .int: .int
        case .double: .double
        case .timestamp: .timestamp
        case .bytes: .bytes
        case .location: .location
        case .reference: .reference
        case .asset: .asset
        case .stringList: .stringList
        case .intList: .intList
        case .doubleList: .doubleList
        case .timestampList: .timestampList
        case .locationList: .locationList
        case .assetList: .assetList
        }
    }

    var isList: Bool {
        switch self {
        case .stringList, .intList, .doubleList, .timestampList, .locationList, .assetList: true
        default: false
        }
    }

    func matches(_ value: RecordValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.text, .string), (.int, .int), (.double, .double),
            (.timestamp, .date), (.bytes, .bytes), (.location, .location), (.reference, .reference), (.asset, .asset),
            (.stringList, .strings), (.intList, .ints), (.doubleList, .doubles), (.timestampList, .dates),
            (.locationList, .locations), (.assetList, .assets):
            true
        default:
            false
        }
    }
}

enum Storage: Equatable, Sendable {
    case slot(Pool, String)
    case payload
}

extension Storage: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "payload" {
            self = .payload
        } else if let separator = raw.firstIndex(of: "_"), let pool = Pool(rawValue: String(raw[..<separator])) {
            self = .slot(pool, raw)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown storage '\(raw)'"))
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

enum UniversalSchemaError: Error, Equatable {
    case unknownEntity(String)
    case unknownField(String)
    case typeMismatch(String)
    case missingField(String)
    case invalidValue(String)
    case missingKey(String)
    case notFound(String)
    case staleSchema(entity: String, version: Int)
    case invalidDefinition(String)
}
