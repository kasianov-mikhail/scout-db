//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct GridTotal {
    let kind: Metric
    var value: Double

    var isNoop: Bool {
        kind.isReversible && value == 0
    }

    static prefix func - (total: GridTotal) -> GridTotal {
        GridTotal(kind: total.kind, value: -total.value)
    }

    static func + (lhs: GridTotal, rhs: GridTotal) -> GridTotal {
        GridTotal(kind: lhs.kind, value: lhs.kind.combine(lhs.value, rhs.value))
    }
}
