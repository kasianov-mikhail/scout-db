//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

private struct IndexedBatch<Element>: @unchecked Sendable {
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
    fileprivate func ordered<Item>() -> [Item] where Element == IndexedBatch<Item> {
        sorted().flatMap(\.items)
    }

    /// The batches `body` makes of every element, run at once and flattened
    /// back into the order the elements came in.
    ///
    /// Tasks complete in whatever order they finish; each batch carries the
    /// position it was started from, so the result does not inherit that order.
    func orderedBatches<Item>(_ body: @escaping @Sendable (Element) async throws -> [Item]) async throws -> [Item]
    where Element: Sendable {
        try await withThrowingTaskGroup(of: IndexedBatch<Item>.self) { group in
            for (index, element) in enumerated() {
                group.addTask {
                    try await IndexedBatch(index: index, items: body(element))
                }
            }
            var batches: [IndexedBatch<Item>] = []
            for try await batch in group {
                batches.append(batch)
            }
            return batches.ordered()
        }
    }
}
