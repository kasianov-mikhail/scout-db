//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

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

    func count(week: Date) -> Int? {
        [grown[week.millisecondsSince1970], floor].compactMap(\.self).max()
    }

    func shards(week: Date) -> [Int?] {
        count(week: week).map { (0..<$0).map(Optional.init) } ?? [nil]
    }
}
