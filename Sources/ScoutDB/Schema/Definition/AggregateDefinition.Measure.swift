//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension AggregateDefinition {
    enum Measure: Equatable, Sendable {
        case sum(String)
        case min(String)
        case max(String)
        case histogram(Histogram)
    }
}

extension AggregateDefinition.Measure {
    var metric: Metric? {
        switch self {
        case .sum:
            .sum
        case .min:
            .min
        case .max:
            .max
        case .histogram:
            nil
        }
    }

    var field: String? {
        switch self {
        case .sum(let field), .min(let field), .max(let field):
            field
        case .histogram:
            nil
        }
    }

    var histogram: AggregateDefinition.Histogram? {
        guard case .histogram(let histogram) = self else {
            return nil
        }
        return histogram
    }
}
