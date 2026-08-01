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

    var shards: Int?

    init(
        name: String, groupBy: String? = nil, sum: String? = nil, min: String? = nil, max: String? = nil,
        shards: Int? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.sum = sum
        self.min = min
        self.max = max
        self.shards = shards
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
        return nil
    }

    func answers(_ kind: Metric, of field: String) -> Bool {
        switch kind {
        case .sum:
            sum == field
        case .min:
            min == field
        case .max:
            max == field
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
