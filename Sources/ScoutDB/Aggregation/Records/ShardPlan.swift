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
        self.floor = floor
        self.grown = Dictionary(
            grown.compactMap { key, value in Int64(key).map { ($0, value) } },
            uniquingKeysWith: Swift.max
        )
    }

    func count(for week: Date) -> Int? {
        [grown[week.millisecondsSince1970], floor].compactMap(\.self).max()
    }
}
