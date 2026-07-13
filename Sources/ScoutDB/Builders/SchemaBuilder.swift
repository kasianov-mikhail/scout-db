//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A chainable schema builder that assigns slots and versions automatically.
///
/// ```swift
/// try await store.schema("purchase")
///     .field("product_id", .string, .required)
///     .field("amount", .double)
///     .field("date", .timestamp)
///     .field("comment", .string, .payload)
///     .envelopeDate("date")
///     .unique(on: "product_id", "date")
///     .create()
/// ```
///
/// `update()` publishes the next version: unchanged fields keep their slots,
/// retyped fields move to a fresh slot, and omitted fields are closed — old
/// records remain readable through their own version forever.
///
public struct SchemaBuilder {
    let entity: String
    let registry: SchemaRegistry

    private var declarations: [Declaration] = []
    private var envelopeDate: String?
    private var unique: [String]?
    private var uniqueKeys: [[String]]?
    private var views: [AggregateView]?
    private var keyID: String?
    private var ttl: Double?

    init(entity: String, registry: SchemaRegistry) {
        self.entity = entity
        self.registry = registry
    }

    /// A constraint applied to a single field declaration.
    public enum FieldConstraint: Sendable {
        case required
        case payload
        case encrypted
        case allowed([String])
        case defaultValue(RecordValue)
        case minimum(Double)
        case maximum(Double)
        case derived(from: String, Derivation.Transform)
        case references(String)
        case exclusiveReference(String)
        case matches(String)
    }

    private struct Declaration {
        let name: String
        let type: FieldType
        let constraints: [FieldConstraint]

        var wantsSlot: Bool {
            !constraints.contains { if case .payload = $0 { true } else { false } }
        }
    }

    /// Declares a field; it gets the next free slot of its pool unless marked `.payload`.
    public func field(_ name: String, _ type: FieldType, _ constraints: FieldConstraint...) -> Self {
        var builder = self
        builder.declarations.append(Declaration(name: name, type: type, constraints: constraints))
        return builder
    }

    /// Names the timestamp field used for pagination, TTL, and views.
    public func envelopeDate(_ field: String) -> Self {
        var builder = self
        builder.envelopeDate = field
        return builder
    }

    /// Derives the record id from the named fields, turning writes into upserts.
    public func unique(on fields: String...) -> Self {
        var builder = self
        builder.unique = fields
        return builder
    }

    /// Adds an enforced uniqueness constraint over the named fields.
    ///
    /// Unlike `unique(on:)`, which derives the record's identity, a unique key
    /// only rejects writes that would duplicate another live record's values —
    /// declare several for independent keys (an email and a username). Records
    /// missing any of the key's fields are exempt. The check is client-side
    /// and best-effort under concurrency, like the reference checks.
    ///
    public func uniqueKey(on fields: String...) -> Self {
        var builder = self
        builder.uniqueKeys = (uniqueKeys ?? []) + [fields]
        return builder
    }

    /// Adds a materialized aggregate view maintained on every write.
    public func view(_ view: AggregateView) -> Self {
        var builder = self
        builder.views = (views ?? []) + [view]
        return builder
    }

    /// Names the encryption key for `.encrypted` fields and `hmac` derivations.
    public func keyID(_ keyID: String) -> Self {
        var builder = self
        builder.keyID = keyID
        return builder
    }

    /// Stamps an expiry on every record, offset from the envelope date.
    public func ttl(_ seconds: Double) -> Self {
        var builder = self
        builder.ttl = seconds
        return builder
    }

    /// Publishes version 1 of the entity.
    public func create() async throws {
        var allocator = SlotAllocator()
        let fields = try declarations.map { try resolve($0, allocator: &allocator, since: nil) }
        try await publish(fields: fields, version: 1, inheriting: nil)
    }

    /// Publishes the next version, diffed against the current one.
    public func update() async throws {
        let previous = try await registry.definition(for: entity)
        let version = previous.version + 1
        var allocator = SlotAllocator(reserving: previous.fields)
        var fields: [FieldDefinition] = []
        var carried: Set<String> = []

        for declaration in declarations {
            let active = previous.fields(at: previous.version).first { $0.name == declaration.name }
            if let active, active.type == declaration.type, active.storage.isSlot == declaration.wantsSlot {
                var kept = try resolve(declaration, allocator: &allocator, since: active.since, storage: active.storage)
                kept.until = active.until
                fields.append(kept)
                carried.insert(declaration.name)
            } else {
                fields.append(try resolve(declaration, allocator: &allocator, since: version))
            }
        }
        for field in previous.fields {
            let redeclared = carried.contains(field.name) && field.isActive(at: previous.version)
            if redeclared { continue }
            var closed = field
            if field.isActive(at: previous.version), field.until == nil {
                closed.until = version
            }
            fields.append(closed)
        }

        try await publish(fields: fields, version: version, inheriting: previous)
    }

    private func publish(fields: [FieldDefinition], version: Int, inheriting previous: EntityDefinition?) async throws {
        let definition = EntityDefinition(
            entity: entity,
            version: version,
            fields: fields,
            envelopeDate: envelopeDate ?? previous?.envelopeDate,
            unique: unique ?? previous?.unique,
            uniqueKeys: uniqueKeys ?? previous?.uniqueKeys,
            views: views ?? previous?.views,
            keyID: keyID ?? previous?.keyID,
            ttl: ttl ?? previous?.ttl
        )
        try await registry.publish(definition)
    }

    private func resolve(_ declaration: Declaration, allocator: inout SlotAllocator, since: Int?, storage: Storage? = nil) throws -> FieldDefinition {
        let resolved: Storage
        if let storage {
            resolved = storage
        } else if declaration.wantsSlot {
            let pool = declaration.type.pool
            resolved = .slot(pool, try allocator.next(in: pool))
        } else {
            resolved = .payload
        }

        var field = FieldDefinition(name: declaration.name, type: declaration.type, storage: resolved, since: since)
        for constraint in declaration.constraints {
            switch constraint {
            case .required: field.required = true
            case .payload: break
            case .encrypted: field.encrypted = true
            case .allowed(let values): field.allowed = values
            case .defaultValue(let value): field.defaultValue = value
            case .minimum(let value): field.minimum = value
            case .maximum(let value): field.maximum = value
            case .derived(let source, let transform): field.derived = Derivation(source: source, transform: transform)
            case .references(let entity): field.references = entity
            case .exclusiveReference(let entity):
                field.references = entity
                field.exclusive = true
            case .matches(let pattern): field.pattern = pattern
            }
        }
        return field
    }
}

// Hands out the lowest free slot per pool. Slots of every historical field stay
// reserved: reusing one while old records exist would mix values of two fields.
private struct SlotAllocator {
    private var used: [Pool: Set<String>] = [:]

    init(reserving fields: [FieldDefinition] = []) {
        for field in fields {
            guard case .slot(let pool, let slot) = field.storage else { continue }
            used[pool, default: []].insert(slot)
        }
    }

    mutating func next(in pool: Pool) throws -> String {
        for index in 0..<pool.capacity {
            let slot = pool.slotName(index)
            if used[pool, default: []].contains(slot) { continue }
            used[pool, default: []].insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition("The '\(pool.rawValue)' pool is exhausted")
    }
}

extension Storage {
    fileprivate var isSlot: Bool {
        if case .slot = self { return true }
        return false
    }
}

extension EntityStore {
    /// Opens a Fluent-style schema builder for an entity.
    public func schema(_ entity: String) -> SchemaBuilder {
        SchemaBuilder(entity: entity, registry: registry)
    }
}
