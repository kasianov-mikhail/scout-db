//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SlotAllocator {
    mutating func storage(declaration: SchemaBuilder.Declaration) throws -> Storage {
        guard declaration.wantsSlot else {
            return .payload(try nextPayload())
        }
        return .slot(declaration.type, try next(pool: declaration.type))
    }

    private mutating func next(pool: FieldType) throws -> String {
        for index in pool.reserved..<pool.capacity {
            let slot = pool.slot(index: index)
            if used[pool, default: []].contains(slot) {
                continue
            }
            used[pool, default: []].insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition(.exhaustedPool(pool))
    }

    private mutating func nextPayload() throws -> String {
        for index in 0..<PayloadPool.capacity {
            let slot = PayloadPool.slot(index: index)
            if usedPayload.contains(slot) {
                continue
            }
            usedPayload.insert(slot)
            return slot
        }
        throw SchemaError.invalidDefinition(.exhaustedPayload)
    }
}
