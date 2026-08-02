//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

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
            let slot = "\(pool.slotPrefix)_\(String(format: "%02d", index))"
            if used[pool, default: []].contains(slot) {
                continue
            }
            used[pool, default: []].insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition("The '\(pool.rawValue)' pool is exhausted")
    }

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
            switch constraint {
            case .required:
                field.required = true
            case .payload:
                break
            case .allowed(let values):
                field.allowed = values
            case .defaultValue(let value):
                field.defaultValue = value
            case .min(let value):
                field.min = value
            case .max(let value):
                field.max = value
            case .matches(let pattern):
                field.pattern = pattern
            case .ungrouped:
                field.ungrouped = true
            }
        }
        return field
    }
}
