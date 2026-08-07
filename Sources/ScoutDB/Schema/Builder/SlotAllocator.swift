//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct SlotAllocator {
    var used: [FieldType: Set<String>] = [:]

    var usedPayload: Set<String> = []

    init(reserving fields: [FieldDefinition]) {
        for field in fields {
            switch field.storage {
            case .slot(let pool, let slot):
                used[pool, default: []].insert(slot)
            case .payload(let slot):
                usedPayload.insert(slot)
            }
        }
    }
}
