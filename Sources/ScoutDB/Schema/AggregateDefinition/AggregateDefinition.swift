//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation

struct AggregateDefinition: Equatable, Sendable {
    let groupBy: String?
    let measure: Measure?
    let shards: Int?
    let date: String?

    var name: String {
        let parts =
            if let histogram = measure?.histogram {
                [
                    "histogram_\(histogram.field)", date.map { "at_\($0)" },
                ]
            } else {
                [
                    measure?.metric?.label,
                    measure?.field,
                    groupBy.map { "by_\($0)" },
                    date.map { "at_\($0)" },
                ]
            }

        let joined = parts.compactMap(\.self)

        return joined.isEmpty ? "by_all" : joined.joined(separator: "_")
    }

    var fold: Metric {
        measure?.metric ?? .sum
    }
}

extension [AggregateDefinition] {
    func covering(_ field: String?, folding metric: Metric) -> AggregateDefinition? {
        first {
            $0.measure?.histogram == nil && $0.measure?.field == field
                && (field == nil || $0.measure?.metric == metric.storage)
        }
    }
}

extension AggregateDefinition {
    init(
        metric: Metric? = nil, field: String? = nil, group: String? = nil, date: String? = nil,
        shards: Int? = nil
    ) {
        let measure: Measure? =
            switch (metric?.storage, field) {
            case (.sum, let field?):
                .sum(field)
            case (.min, let field?):
                .min(field)
            case (.max, let field?):
                .max(field)
            default:
                nil
            }

        self.init(groupBy: group, measure: measure, shards: shards, date: date)
    }

    init(histogram field: String, bounds: [Double], group: String? = nil, date: String? = nil) {
        self.init(
            groupBy: group,
            measure: .histogram(.init(field: field, bounds: bounds)),
            shards: nil,
            date: date
        )
    }
}
