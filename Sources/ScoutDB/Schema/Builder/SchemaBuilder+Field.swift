//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
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
        builder.declarations.append(Declaration(name: name, type: type, constraints: constraints))
        return builder
    }
}

extension SlotAllocator {
    mutating func resolve(_ declaration: SchemaBuilder.Declaration, since: Int?, storage: Storage? = nil)
        throws -> FieldDefinition
    {
        let resolved: Storage

        if let storage {
            resolved = storage
        } else if declaration.wantsSlot {
            let pool = declaration.type
            resolved = .slot(pool, try next(in: pool))
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
            constraint.apply(to: &field)
        }
        return field
    }

    private mutating func next(in pool: FieldType) throws -> String {
        for index in 0..<pool.capacity {
            let slot = "\(pool.slotPrefix)_\(String(format: "%02d", index))"
            if used[pool, default: []].contains(slot) {
                continue
            }
            used[pool, default: []].insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition(.exhaustedPool(pool))
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
