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
}
