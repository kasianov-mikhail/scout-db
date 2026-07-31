//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateView: Codable, Equatable, Sendable {
    let name: String

    var groupBy: String?

    var sum: String?

    var min: String?

    var max: String?

    var stats: String?

    var shards: Int?

    var exact: Bool?

    init(
        name: String, groupBy: String? = nil, sum: String? = nil, min: String? = nil, max: String? = nil, stats: String? = nil,
        shards: Int? = nil, exact: Bool? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.sum = sum
        self.min = min
        self.max = max
        self.stats = stats
        self.shards = shards
        self.exact = exact
    }

    var metric: (kind: Metric, field: String)? {
        if let sum {
            return (.sum, sum)
        }
        if let min {
            return (.min, min)
        }
        if let max {
            return (.max, max)
        }
        if let stats {
            return (.sum, stats)
        }
        return nil
    }

    func answers(_ kind: Metric, of field: String) -> Bool {
        switch kind {
        case .sum:
            sum == field || stats == field
        case .min:
            min == field && exact == true
        case .max:
            max == field && exact == true
        }
    }
}

enum Metric: Equatable, Sendable {
    case sum, min, max

    func combine(_ lhs: Double, _ rhs: Double) -> Double {
        switch self {
        case .sum:
            lhs + rhs
        case .min:
            Swift.min(lhs, rhs)
        case .max:
            Swift.max(lhs, rhs)
        }
    }
}
