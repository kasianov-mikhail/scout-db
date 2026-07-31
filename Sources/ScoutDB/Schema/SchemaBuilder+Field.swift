//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    /// What a field is held to beyond its type.
    ///
    /// Constraints are checked on the device before a write leaves it, so a
    /// rejected value costs nothing and never reaches CloudKit. Several may sit
    /// on one field: `.required` with `.allowed`, `.min` with `.max`.
    ///
    /// ```swift
    /// .field("status", .string, .required, .allowed(["placed", "paid"]))
    /// .field("quantity", .int, .min(1), .max(20))
    /// ```
    ///
    public enum FieldConstraint: Sendable {
        /// Rejects a write that leaves the field without a value, once the
        /// default and the derivation have been applied.
        case required

        /// Keeps the field out of the pools, in the record's payload blob:
        /// unlimited in number, but beyond the server's filters and sorts.
        case payload

        /// Seals the value under the definition's key before it leaves the
        /// device; only a payload field can be encrypted.
        case encrypted

        /// The closed set of strings every value of the field must come from.
        case allowed([String])

        /// The value a write that omits the field gets instead.
        case defaultValue(RecordValue)

        /// The inclusive lower bound every numeric scalar must clear.
        case min(Double)

        /// The inclusive upper bound every numeric scalar must stay under.
        case max(Double)

        /// Makes the field a shadow of another one, recomputed from its source
        /// on every write rather than supplied by the caller.
        case derived(from: String, FieldTransform)

        /// A regular expression every value of the field must match whole.
        case matches(String)

        /// Keeps the field out of the grid a creation builds: nothing counts by
        /// it, and no write pays for its cells. For the fields of many distinct
        /// values — a uuid, a free-form string — that no read groups by.
        case ungrouped
    }

    struct Declaration {
        let name: String
        let type: FieldType
        let constraints: [FieldConstraint]

        var wantsSlot: Bool {
            !constraints.contains { if case .payload = $0 { true } else { false } }
        }
    }

    /// Declares a field of the entity.
    ///
    /// The field takes the next free slot for its type, which is what lets the
    /// server filter and sort on it. Sixteen slots exist per type; a `.payload`
    /// field spends none of them, at the cost of every filter over it running
    /// on the client after decoding. Declaration order fixes the slots, so
    /// keeping it stable across versions keeps records readable without a
    /// rewrite.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("quantity", .int, .min(1), .max(20))
    ///     .field("comment", .string, .payload)
    ///     .create()
    /// ```
    ///
    public func field(_ name: String, _ type: FieldType, _ constraints: FieldConstraint...) -> Self {
        var builder = self
        builder.declarations.append(
            Declaration(
                name: name,
                type: type,
                constraints: constraints
            )
        )
        return builder
    }

    func resolve(_ declaration: Declaration, allocator: inout SlotAllocator, since: Int?, storage: Storage? = nil) throws -> FieldDefinition {
        let resolved: Storage

        if let storage {
            resolved = storage
        } else if declaration.wantsSlot {
            let pool = declaration.type
            resolved = .slot(pool, try allocator.next(in: pool))
        } else {
            resolved = .payload
        }

        var field = FieldDefinition(
            name: declaration.name,
            type: declaration.type,
            storage: resolved,
            since: since
        )

        for constraint in declaration.constraints {
            switch constraint {
            case .required:
                field.required = true
            case .payload:
                break
            case .encrypted:
                field.encrypted = true
            case .allowed(let values):
                field.allowed = values
            case .defaultValue(let value):
                field.defaultValue = value
            case .min(let value):
                field.min = value
            case .max(let value):
                field.max = value
            case .derived(let source, let transform):
                field.derived = Derivation(source: source, transform: transform)
            case .matches(let pattern):
                field.pattern = pattern
            case .ungrouped:
                field.ungrouped = true
            }
        }
        return field
    }
}

struct SlotAllocator {
    var used: [FieldType: Set<String>] = [:]

    init(reserving fields: [FieldDefinition] = []) {
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                used[pool, default: []].insert(slot)
            }
        }
    }

    mutating func next(in pool: FieldType) throws -> String {
        for index in 0..<pool.capacity {
            let slot = pool.slotName(index)
            if used[pool, default: []].contains(slot) {
                continue
            }
            used[pool, default: []].insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition("The '\(pool.rawValue)' pool is exhausted")
    }
}

extension Storage {
    var isSlot: Bool {
        if case .slot = self {
            return true
        }
        return false
    }
}
