//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

private let growthThreshold = 3

struct ShardLayout {
    let plans: [String: ShardPlan]

    init(_ plans: [ShardPlan]) {
        self.plans = Dictionary(uniqueKeysWithValues: plans.map { ($0.aggregate.name, $0) })
    }

    func raised(lost: [VectorSlot: Int]) -> [VectorIndex: IndexPage] {
        var raised: [VectorIndex: [String: Int]] = [:]

        for (slot, count) in lost where count >= growthThreshold {
            let index = slot.headIndex
            let key = String(slot.week.millisecondsSince1970)
            let standing = raised[index]?[key] ?? plans[slot.aggregate]?.count(week: slot.week) ?? 1

            raised[index, default: [:]][key] = standing * 2
        }

        return raised.mapValues { IndexPage(weeks: [], groups: [], shards: $0) }
    }
}
