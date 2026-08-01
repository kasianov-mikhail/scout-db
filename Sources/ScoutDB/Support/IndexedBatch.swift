//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct IndexedBatch<Element>: @unchecked Sendable {
    let index: Int
    let items: [Element]
}

extension IndexedBatch: Comparable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.index < rhs.index
    }
}

extension Sequence {
    func ordered<Item>() -> [Item] where Element == IndexedBatch<Item> {
        sorted().flatMap(\.items)
    }
}
