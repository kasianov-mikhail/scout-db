//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SlotAllocator {
    mutating func resolve(_ declaration: SchemaBuilder.Declaration, since: Int?, storage: Storage?)
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
        for index in pool.reserved..<pool.capacity {
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
