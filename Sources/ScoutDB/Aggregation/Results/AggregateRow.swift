//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateRow: Equatable, Sendable {
    let group: String
    let period: Date
    let count: Int
    let value: Double?
    var squares: Double?
}

extension AggregateRow: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.period, lhs.group) < (rhs.period, rhs.group)
    }
}
