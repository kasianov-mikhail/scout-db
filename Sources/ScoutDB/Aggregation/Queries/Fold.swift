//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

enum Fold: String, Sendable {
    case sum
    case min
    case max
    case average

    var metric: Metric {
        switch self {
        case .sum, .average:
            .sum
        case .min:
            .min
        case .max:
            .max
        }
    }

    func apply(values: [Double], count: Int) -> Double? {
        switch self {
        case .sum:
            values.reduce(0, +)
        case .average:
            values.isEmpty || count == 0 ? nil : values.reduce(0, +) / Double(count)
        case .min, .max:
            values.first.map { values.dropFirst().reduce($0, metric.combine) }
        }
    }
}
