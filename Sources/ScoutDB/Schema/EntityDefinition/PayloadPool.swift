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

    static func slot(_ index: Int) -> String {
        "\(slotPrefix)_\(String(format: "%02d", index))"
    }

    static func slotIndex(_ slot: String) -> Int? {
        guard slot.hasPrefix("\(slotPrefix)_"), let index = Int(slot.dropFirst(slotPrefix.count + 1)) else {
            return nil
        }
        return index >= 0 ? index : nil
    }
}
