//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A per-group metric total paired with its sum of squares, from which the mean
/// and spread derive.
public struct AggregateTotal: Equatable, Sendable {
    public let group: String
    public let count: Int
    public let value: Double?
    public var squares: Double?

    public var average: Double? {
        guard let value, count > 0 else {
            return nil
        }
        return value / Double(count)
    }

    public var variance: Double? {
        guard let value, let squares, count > 0 else {
            return nil
        }
        let mean = value / Double(count)
        return Swift.max(0, squares / Double(count) - mean * mean)
    }

    public var standardDeviation: Double? {
        variance.map(sqrt)
    }
}

extension AggregateTotal: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.group < rhs.group
    }
}
