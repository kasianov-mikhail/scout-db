//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The pool the payload fields draw from: fourteen blob slots, one value each,
/// and none of them within the server's reach.
///
/// A typed pool holds one Swift type and lends the server its filters and
/// sorts; this one holds any type as encoded bytes and lends nothing, so what
/// a field of it costs is the slot alone.
///
enum PayloadPool {
    static let slotPrefix = "p"

    static let capacity = 14

    static func slot(_ index: Int) -> String {
        "\(slotPrefix)_\(String(format: "%02d", index))"
    }

    static func slotIndex(_ slot: String) -> Int? {
        guard slot.hasPrefix("\(slotPrefix)_"), let index = Int(slot.dropFirst(slotPrefix.count + 1)), index >= 0
        else {
            return nil
        }
        return index
    }
}
