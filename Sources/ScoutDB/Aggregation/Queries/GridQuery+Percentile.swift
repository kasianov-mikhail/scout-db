//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension GridQuery {
    func percentile(_ p: Double) async throws -> Double? {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view), let histogram = declared.histogram else {
            throw SchemaError.invalidValue(view)
        }

        var counts = [Double](repeating: 0, count: histogram.bounds.count + 1)

        let records = try await store.gridRecords(
            entity: entity,
            view: view,
            group: group,
            from: declared.gridStart(from: from),
            to: to,
            counts: counts.indices
        )

        for record in records {
            for index in counts.indices {
                counts[index] += Double(record.count(at: index))
            }
        }

        let total = counts.reduce(0, +)

        guard total > 0 else {
            return nil
        }

        let target = p * total
        var cumulative = 0.0

        for (index, count) in counts.enumerated() where count > 0 {
            if cumulative + count >= target {
                if index == 0 {
                    return histogram.bounds.first
                }
                if index == counts.count - 1 {
                    return histogram.bounds.last
                }

                let lower = histogram.bounds[index - 1]
                let upper = histogram.bounds[index]

                return lower + (target - cumulative) / count * (upper - lower)
            }
            cumulative += count
        }

        return histogram.bounds.last
    }
}
