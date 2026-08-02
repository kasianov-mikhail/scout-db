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
}
