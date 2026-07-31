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

    var bucket: AggregateBucket?

    var sum: String?

    var min: String?

    var max: String?

    var stats: String?

    var histogram: Histogram?

    var shards: Int?

    var exact: Bool?

    init(
        name: String, groupBy: String? = nil, bucket: AggregateBucket? = nil, sum: String? = nil, min: String? = nil, max: String? = nil, stats: String? = nil,
        histogram: Histogram? = nil, shards: Int? = nil, exact: Bool? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.bucket = bucket
        self.sum = sum
        self.min = min
        self.max = max
        self.stats = stats
        self.histogram = histogram
        self.shards = shards
        self.exact = exact
    }

    struct Histogram: Codable, Equatable, Sendable {
        let field: String

        let bounds: [Double]
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

/// The period one grid cell of an aggregate covers.
public enum AggregateBucket: String, Codable, Sendable {
    /// Cells an hour wide, or a day wide — `weekday` and `day` both read per
    /// day and differ only in how many cells share a grid record, a week's
    /// worth or a month's.
    case hour, weekday, day

    /// One running total per group, with no time grid — the categorical
    /// counter. The only bucket that works without an envelope date.
    case lifetime
}
