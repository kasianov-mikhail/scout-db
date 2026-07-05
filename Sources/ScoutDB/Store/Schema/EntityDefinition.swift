//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct EntityDefinition: Codable, Equatable, Sendable {
    public let entity: String
    public let version: Int
    public let fields: [FieldDefinition]
    public var envelopeDate: String?
    public var unique: [String]?
    public var views: [AggregateView]?
    public var keyID: String?
    public var ttl: Double?

    public init(
        entity: String, version: Int, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil, views: [AggregateView]? = nil,
        keyID: String? = nil, ttl: Double? = nil
    ) {
        self.entity = entity
        self.version = version
        self.fields = fields
        self.envelopeDate = envelopeDate
        self.unique = unique
        self.views = views
        self.keyID = keyID
        self.ttl = ttl
    }

    public func fields(at version: Int) -> [FieldDefinition] {
        fields.filter { $0.isActive(at: version) }
    }

    public func validate() throws {
        let names = Set(fields.map(\.name))
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                guard field.type.pool == pool else {
                    throw SchemaError.invalidDefinition(
                        "Field '\(field.name)' of type '\(field.type.rawValue)' cannot live in the '\(pool.rawValue)' pool")
                }
                guard slot.hasPrefix("\(pool.rawValue)_"), let index = Int(slot.dropFirst(pool.rawValue.count + 1)), index >= 0 else {
                    throw SchemaError.invalidDefinition("Slot '\(slot)' does not belong to the '\(pool.rawValue)' pool")
                }
                guard index < pool.capacity else {
                    throw SchemaError.invalidDefinition("Slot '\(slot)' is beyond the '\(pool.rawValue)' pool capacity of \(pool.capacity)")
                }
            }
            if field.type == .asset, field.storage == .payload {
                throw SchemaError.invalidDefinition("Asset field '\(field.name)' must live in an asset slot")
            }
            if let derived = field.derived, !names.contains(derived.source) {
                throw SchemaError.invalidDefinition("Field '\(field.name)' derives from unknown '\(derived.source)'")
            }
            if field.derived?.transform == .ngrams, field.type != .stringList {
                throw SchemaError.invalidDefinition("Ngram field '\(field.name)' must be a string list")
            }
            if field.encrypted == true, field.storage != .payload {
                throw SchemaError.invalidDefinition("Encrypted field '\(field.name)' must live in payload")
            }
            if field.encrypted == true || field.derived?.transform == .hmac, keyID == nil {
                throw SchemaError.invalidDefinition("Field '\(field.name)' needs a keyID on the definition")
            }
            if field.references != nil, field.type != .string {
                throw SchemaError.invalidDefinition("Reference field '\(field.name)' must be a string uuid")
            }
            if field.allowed != nil, ![.string, .text, .stringList].contains(field.type) {
                throw SchemaError.invalidDefinition("Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'allowed'")
            }
            if field.minimum != nil || field.maximum != nil, ![.int, .double, .intList, .doubleList].contains(field.type) {
                throw SchemaError.invalidDefinition("Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'minimum'/'maximum'")
            }
        }
        for lhs in fields {
            for rhs in fields where lhs.name != rhs.name || lhs.since != rhs.since {
                guard case .slot(_, let lhsSlot) = lhs.storage else { continue }
                guard case .slot(_, let rhsSlot) = rhs.storage else { continue }
                if lhsSlot == rhsSlot, lhs.overlaps(rhs) {
                    throw SchemaError.invalidDefinition("Fields '\(lhs.name)' and '\(rhs.name)' share slot '\(lhsSlot)'")
                }
            }
        }
        if let envelopeDate {
            guard fields.first(where: { $0.name == envelopeDate })?.type == .timestamp else {
                throw SchemaError.invalidDefinition("Envelope date '\(envelopeDate)' is not a timestamp field")
            }
        }
        if ttl != nil, envelopeDate == nil {
            throw SchemaError.invalidDefinition("TTL requires an envelope date")
        }
        for key in unique ?? [] where !names.contains(key) {
            throw SchemaError.invalidDefinition("Unique key '\(key)' is not a field")
        }
        for view in views ?? [] {
            guard envelopeDate != nil else {
                throw SchemaError.invalidDefinition("View '\(view.name)' requires an envelope date")
            }
            if let groupBy = view.groupBy, !names.contains(groupBy) {
                throw SchemaError.invalidDefinition("View '\(view.name)' groups by unknown '\(groupBy)'")
            }
            let metrics = [view.sum, view.min, view.max, view.stats, view.histogram?.field].compactMap { $0 }
            guard metrics.count <= 1 else {
                throw SchemaError.invalidDefinition("View '\(view.name)' declares more than one metric")
            }
            for field in metrics {
                guard let type = fields.first(where: { $0.name == field })?.type, type == .int || type == .double else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' aggregates non-numeric '\(field)'")
                }
            }
            if let histogram = view.histogram {
                guard histogram.bounds.count > 0, histogram.bounds.count < 64, histogram.bounds == histogram.bounds.sorted() else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' has invalid histogram bounds")
                }
                guard view.bucket == nil else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' cannot combine a histogram with a time bucket")
                }
            }
        }
    }
}

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

    public init(
        name: String, type: FieldType, storage: Storage, since: Int? = nil, until: Int? = nil, required: Bool? = nil, defaultValue: RecordValue? = nil,
        allowed: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil, derived: Derivation? = nil, encrypted: Bool? = nil, references: String? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, storage, since, until, required, allowed, minimum, maximum, derived, encrypted, references
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

public struct AggregateView: Codable, Equatable, Sendable {
    public let name: String
    public var groupBy: String?
    public var bucket: Bucket?
    public var sum: String?
    public var min: String?
    public var max: String?
    public var stats: String?
    public var histogram: Histogram?

    public init(
        name: String, groupBy: String? = nil, bucket: Bucket? = nil, sum: String? = nil, min: String? = nil, max: String? = nil, stats: String? = nil,
        histogram: Histogram? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.bucket = bucket
        self.sum = sum
        self.min = min
        self.max = max
        self.stats = stats
        self.histogram = histogram
    }

    public struct Histogram: Codable, Equatable, Sendable {
        public let field: String
        public let bounds: [Double]

        public init(field: String, bounds: [Double]) {
            self.field = field
            self.bounds = bounds
        }
    }

    public enum Bucket: String, Codable, Sendable {
        case hour, weekday, day
    }

    public enum Metric: Equatable, Sendable {
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

public enum FieldType: String, Codable, Equatable, Sendable {
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

    var emptyList: RecordValue? {
        switch self {
        case .stringList: .strings([])
        case .intList: .ints([])
        case .doubleList: .doubles([])
        case .timestampList: .dates([])
        case .locationList: .locations([])
        case .assetList: .assets([])
        default: nil
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

public enum Storage: Equatable, Sendable {
    case slot(Pool, String)
    case payload
}

extension Storage: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "payload" {
            self = .payload
        } else if let separator = raw.firstIndex(of: "_"), let pool = Pool(rawValue: String(raw[..<separator])) {
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

public enum SchemaError: Error, Equatable {
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
