//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct ShardPlan: Equatable {
    let aggregate: AggregateDefinition
    private var grown: [Int64: Int]

    init(aggregate: AggregateDefinition, head: IndexPage?) {
        var weeks: [Int64: Int] = [:]
        for (key, value) in head?.shards ?? [:] {
            guard let week = Int64(key) else {
                continue
            }
            weeks[week] = Swift.max(weeks[week] ?? value, value)
        }
        self.aggregate = aggregate
        self.grown = weeks
    }

    func count(week: Date) -> Int? {
        [grown[week.millisecondsSince1970], aggregate.shards].compactMap(\.self).max()
    }

    func shards(week: Date) -> [Int?] {
        count(week: week).map { (0..<$0).map(Optional.init) } ?? [nil]
    }
}
