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
    private let index = FieldIndex()
    public var envelopeDate: String?
    public var unique: [String]?
    /// Enforced uniqueness constraints, one field tuple each — unlike `unique`,
    /// they reject duplicates instead of deriving the record's identity.
    public var uniqueKeys: [[String]]?
    /// Claim-backed uniqueness constraints: each key value is held by a claim
    /// record whose creation is a compare-and-swap, so two racing writers cannot
    /// both win — unlike `uniqueKeys`, which validates by a separate read.
    public var enforcedKeys: [[String]]?
    public var views: [AggregateView]?
    public var keyID: String?
    /// An audited entity appends a revision record on every update and delete;
    /// publish `EntityStore.revisionDefinition` before enabling it.
    public var audited: Bool?

    public init(
        entity: String, version: Int, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil,
        uniqueKeys: [[String]]? = nil, enforcedKeys: [[String]]? = nil, views: [AggregateView]? = nil, keyID: String? = nil,
        audited: Bool? = nil
    ) {
        self.entity = entity
        self.version = version
        self.fields = fields
        self.envelopeDate = envelopeDate
        self.unique = unique
        self.uniqueKeys = uniqueKeys
        self.enforcedKeys = enforcedKeys
        self.views = views
        self.keyID = keyID
        self.audited = audited
    }

    private enum CodingKeys: String, CodingKey {
        case entity, version, fields, envelopeDate, unique, uniqueKeys, enforcedKeys, views, keyID, audited
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entity == rhs.entity && lhs.version == rhs.version && lhs.fields == rhs.fields && lhs.envelopeDate == rhs.envelopeDate
            && lhs.unique == rhs.unique && lhs.uniqueKeys == rhs.uniqueKeys && lhs.enforcedKeys == rhs.enforcedKeys && lhs.views == rhs.views
            && lhs.keyID == rhs.keyID && lhs.audited == rhs.audited
    }

    public func fields(at version: Int) -> [FieldDefinition] {
        index.entry(at: version, of: fields).active
    }

    /// The active field with the given name, resolving duplicate historical names
    /// in favor of the first declaration — the one shared tie-break policy.
    public func field(named name: String, at version: Int) -> FieldDefinition? {
        index.entry(at: version, of: fields).byName[name]
    }

    func fieldsByName(at version: Int) -> [String: FieldDefinition] {
        index.entry(at: version, of: fields).byName
    }

    func view(named name: String) -> AggregateView? {
        views?.first { $0.name == name }
    }

    /// The publish-time validation: everything `validate()` checks, plus the
    /// shapes that are legal to read back but wasteful to ever publish anew.
    ///
    /// A `uniqueKeys` tuple with no slot-backed field gives the server nothing
    /// to narrow on, so every write batch would scan the whole entity; it is
    /// rejected here while already-published definitions keep decoding.
    ///
    public func validateForPublish() throws {
        try validate()
        for key in uniqueKeys ?? [] {
            let backed = key.contains { name in
                guard case .slot? = field(named: name, at: version)?.storage else { return false }
                return true
            }
            guard backed else {
                throw SchemaError.invalidDefinition(
                    "Unique key '\(key.joined(separator: ", "))' has no slot-backed field, so every write would scan the whole entity")
            }
        }
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
            if let pattern = field.pattern {
                guard [.string, .text, .stringList].contains(field.type) else {
                    throw SchemaError.invalidDefinition("Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'pattern'")
                }
                guard (try? Regex(pattern)) != nil else {
                    throw SchemaError.invalidDefinition("Field '\(field.name)' declares a malformed pattern")
                }
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
            guard field(named: envelopeDate, at: version)?.type == .timestamp else {
                throw SchemaError.invalidDefinition("Envelope date '\(envelopeDate)' is not an active timestamp field at version \(version)")
            }
        }
        for key in unique ?? [] where !names.contains(key) {
            throw SchemaError.invalidDefinition("Unique key '\(key)' is not a field")
        }
        for key in (uniqueKeys ?? []) + (enforcedKeys ?? []) {
            guard !key.isEmpty else {
                throw SchemaError.invalidDefinition("A unique key cannot be empty")
            }
            for field in key where !names.contains(field) {
                throw SchemaError.invalidDefinition("Unique key field '\(field)' is not a field")
            }
        }
        for view in views ?? [] {
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
            if let shards = view.shards, !(2...64).contains(shards) {
                throw SchemaError.invalidDefinition("View '\(view.name)' must shard into 2...64 records")
            }
            if view.exact == true {
                guard view.min != nil || view.max != nil else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' can only keep a min or max exact")
                }
                guard view.shards == nil else {
                    throw SchemaError.invalidDefinition("View '\(view.name)' cannot keep an extremum exact across shards")
                }
                if let groupBy = view.groupBy {
                    guard let field = field(named: groupBy, at: version), case .slot = field.storage, field.encrypted != true else {
                        throw SchemaError.invalidDefinition("View '\(view.name)' can only keep an extremum exact when it groups by a filterable field")
                    }
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

private final class FieldIndex: @unchecked Sendable {
    struct Entry {
        let active: [FieldDefinition]
        let byName: [String: FieldDefinition]
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func entry(at version: Int, of fields: [FieldDefinition]) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[version] { return cached }
        let active = fields.filter { $0.isActive(at: version) }
        let entry = Entry(active: active, byName: Dictionary(active.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        entries[version] = entry
        return entry
    }
}
