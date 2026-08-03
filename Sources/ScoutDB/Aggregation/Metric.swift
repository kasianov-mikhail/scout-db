//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The fold a metric applies to the values it gathers.
public enum Metric: String, Equatable, Sendable {
    case sum
    case min
    case max
    case average
}

extension Metric {
    var storage: Metric {
        self == .average ? .sum : self
    }

    var label: String {
        storage.rawValue
    }

    var isReversible: Bool {
        storage == .sum
    }

    func combine(_ lhs: Double, _ rhs: Double) -> Double {
        switch self {
        case .sum, .average:
            lhs + rhs
        case .min:
            Swift.min(lhs, rhs)
        case .max:
            Swift.max(lhs, rhs)
        }
    }

    func apply(values: [Double], count: Int) -> Double? {
        switch self {
        case .sum:
            values.reduce(0, +)
        case .average:
            values.isEmpty || count == 0 ? nil : values.reduce(0, +) / Double(count)
        case .min, .max:
            values.first.map { values.dropFirst().reduce($0, combine) }
        }
    }
}
