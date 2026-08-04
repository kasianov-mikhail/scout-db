//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension AggregateDefinition.Histogram {
    func percentile(_ rank: Double, over counts: [Int]) -> Double? {
        let total = counts.reduce(0, +)

        guard total > 0 else {
            return nil
        }

        let target = Double(total) * rank
        var cumulative = 0.0

        for (index, bin) in counts.enumerated() where bin > 0 {
            let count = Double(bin)

            guard cumulative + count >= target else {
                cumulative += count
                continue
            }
            guard index > 0 else {
                return bounds.first
            }
            guard index < counts.count - 1 else {
                return bounds.last
            }

            let lower = bounds[index - 1]
            let upper = bounds[index]

            return lower + (target - cumulative) / count * (upper - lower)
        }

        return bounds.last
    }
}
