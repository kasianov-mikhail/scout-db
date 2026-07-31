//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct AggregateSeriesPoint: Equatable, Sendable {
    public let group: String
    public let date: Date
    public let count: Int
    public let value: Double?
}

extension AggregateSeriesPoint: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.date, lhs.group) < (rhs.date, rhs.group)
    }
}
