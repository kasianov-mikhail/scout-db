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
    /// An audited entity appends a revision record on every update and delete;
    /// publish `EntityStore.revisionDefinition` before enabling it.
    public var audited: Bool?

    public init(
        entity: String, version: Int, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil, views: [AggregateView]? = nil,
        keyID: String? = nil, ttl: Double? = nil, audited: Bool? = nil
    ) {
        self.entity = entity
        self.version = version
        self.fields = fields
        self.envelopeDate = envelopeDate
        self.unique = unique
        self.views = views
        self.keyID = keyID
        self.ttl = ttl
        self.audited = audited
    }

    public func fields(at version: Int) -> [FieldDefinition] {
        fields.filter { $0.isActive(at: version) }
    }

    /// The active field with the given name, resolving duplicate historical names
    /// in favor of the first declaration — the one shared tie-break policy.
    public func field(named name: String, at version: Int) -> FieldDefinition? {
        fields(at: version).first { $0.name == name }
    }

    func fieldsByName(at version: Int) -> [String: FieldDefinition] {
        Dictionary(fields(at: version).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func view(named name: String) -> AggregateView? {
        views?.first { $0.name == name }
    }

    public func validate() throws {
        let names = Set(fields.map(\.name))
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                guard field.type.pool == pool else {
                    throw SchemaError.invalidDefinition(
                        "Field '\(field.name)' of type '\(field.type.rawValue)' cannot live in the '\(pool.rawValue)' pool")
                }
                guard let index = pool.slotIndex(slot) else {
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
            if field.references != nil, ![.string, .stringList].contains(field.type) {
                throw SchemaError.invalidDefinition("Reference field '\(field.name)' must be a string uuid or a string list of uuids")
            }
            if field.exclusive == true, field.references == nil || field.type != .string {
                throw SchemaError.invalidDefinition("Exclusive field '\(field.name)' must be a scalar string reference")
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
            // A lifetime view has no time grid, so it alone works without a date.
            if view.bucket != .lifetime || view.histogram != nil {
                guard envelopeDate != nil else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' requires an envelope date")
                }
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
