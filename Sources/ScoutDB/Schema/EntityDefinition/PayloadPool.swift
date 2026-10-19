//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

enum PayloadPool {
    static let slotPrefix = "p"

    static let capacity = 16

    static func slot(index: Int) -> String {
        String(slotPrefix: slotPrefix, index: index)
    }

    static func slotIndex(slot: String) -> Int? {
        slot.slotIndex(prefix: slotPrefix)
    }
}
