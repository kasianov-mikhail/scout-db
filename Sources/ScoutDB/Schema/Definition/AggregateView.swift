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

    var metricKind: Metric? {
        if sum != nil {
            return .sum
        }
        if min != nil {
            return .min
        }
        if max != nil {
            return .max
        }
        return nil
    }

    var metricField: String? {
        sum ?? min ?? max
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

    /// The same fold with nothing on the left yet, which `rhs` then seeds.
    func combine(_ lhs: Double?, _ rhs: Double) -> Double {
        lhs.map { combine($0, rhs) } ?? rhs
    }

    /// The same fold with either side possibly missing.
    ///
    /// An absent `lhs` is seeded by `rhs`; an absent `rhs` leaves `lhs` as it
    /// was. Kept apart from ``combine(_:_:)-(Double?,Double)`` by name rather
    /// than by overload: the two are ambiguous wherever the result flows into
    /// an optional.
    func accumulate(_ lhs: Double?, _ rhs: Double?) -> Double? {
        rhs.map { combine(lhs, $0) } ?? lhs
    }

    /// Whether a value already folded in can be taken back out.
    ///
    /// Only a sum can: dropping a term from a running minimum or maximum needs
    /// the terms that remain, which a grid cell does not keep.
    var isReversible: Bool { self == .sum }
}
