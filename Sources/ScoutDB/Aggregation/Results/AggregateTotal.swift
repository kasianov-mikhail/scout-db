//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A per-group metric total paired with the count it folds, from which the mean
/// derives.
public struct AggregateTotal: Equatable, Sendable {
    public let group: String
    public let count: Int
    public let value: Double?

    public var average: Double? {
        guard let value, count > 0 else {
            return nil
        }
        return value / Double(count)
    }
}

extension AggregateTotal: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.group < rhs.group
    }
}
