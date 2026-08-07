//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

typealias ShardPlans = [String: ShardPlan]

/// How many records one week of an aggregate spreads a hot cell over.
///
/// The schema's `shards` is the floor, and contention raises a week above it.
/// A week is the unit because a count only rises: reading is what a shard
/// costs, so a Monday that needed sixty-four of them would tax every week
/// after it if the whole aggregate carried one number.
///
struct ShardPlan: Equatable {
    let floor: Int?
    private var grown: [Int64: Int]

    init(floor: Int?, grown: [String: Int] = [:]) {
        self.floor = floor
        self.grown = Dictionary(
            grown.compactMap { key, value in Int64(key).map { ($0, value) } },
            uniquingKeysWith: Swift.max
        )
    }

    func count(for week: Date) -> Int? {
        [grown[week.millisecondsSince1970], floor].compactMap(\.self).max()
    }

    func doubling(_ week: Date) -> Self {
        var raised = self
        raised.grown[week.millisecondsSince1970] = (count(for: week) ?? 1) * 2
        return raised
    }

    var stored: [String: Int] {
        Dictionary(uniqueKeysWithValues: grown.map { (String($0.key), $0.value) })
    }
}

extension ShardPlan {
    init(floor: Int?, page: VectorIndex.Page?) {
        self.init(floor: floor, grown: page?.shards ?? [:])
    }

    /// The shard numbers a reader has to cover for the week, `[nil]` where the
    /// week is unsharded and the vector is reached by its bare name.
    func shards(for week: Date) -> [Int?] {
        guard let count = count(for: week) else {
            return [nil]
        }
        return (0..<count).map(Optional.init)
    }
}
