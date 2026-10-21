//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

private let growthThreshold = 3

typealias ShardPlans = [String: ShardPlan]

struct ShardPlan: Equatable {
    let floor: Int?
    private var grown: [Int64: Int]

    init(floor: Int?, grown: [String: Int] = [:]) {
        var weeks: [Int64: Int] = [:]
        for (key, value) in grown {
            guard let week = Int64(key) else {
                continue
            }
            weeks[week] = Swift.max(weeks[week] ?? value, value)
        }
        self.floor = floor
        self.grown = weeks
    }

    init(aggregate: AggregateDefinition, head: IndexPage?) {
        self.init(floor: aggregate.shards, grown: head?.shards ?? [:])
    }

    func count(week: Date) -> Int? {
        [grown[week.millisecondsSince1970], floor].compactMap(\.self).max()
    }

    func shards(week: Date) -> [Int?] {
        count(week: week).map { (0..<$0).map(Optional.init) } ?? [nil]
    }
}

extension ShardPlans {
    func raised(lost: [VectorSlot: Int]) -> [VectorIndex: IndexPage] {
        var raised: [VectorIndex: [String: Int]] = [:]

        for (slot, count) in lost where count >= growthThreshold {
            let index = slot.headIndex
            let key = String(slot.week.millisecondsSince1970)
            let standing = raised[index]?[key] ?? self[slot.aggregate]?.count(week: slot.week) ?? 1

            raised[index, default: [:]][key] = standing * 2
        }

        return raised.mapValues { IndexPage(weeks: [], groups: [], shards: $0) }
    }
}
