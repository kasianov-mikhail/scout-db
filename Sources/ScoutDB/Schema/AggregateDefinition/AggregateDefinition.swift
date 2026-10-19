//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation

struct AggregateDefinition: Equatable, Sendable {
    let groups: [String]
    let measure: Measure?
    let shards: Int?
    let date: String?
    var since: Date?

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
                    groups.isEmpty ? nil : "by_" + groups.joined(separator: "+"),
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
    init(metric: Metric? = nil, field: String? = nil, group: String? = nil, date: String? = nil, shards: Int? = nil) {
        self.init(metric: metric, field: field, groups: group.map { [$0] } ?? [], date: date, shards: shards)
    }

    init(metric: Metric?, field: String?, groups: [String], date: String?, shards: Int?) {
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

        self.init(groups: groups, measure: measure, shards: shards, date: date)
    }

    init(histogram field: String, bounds: [Double], group: String?, date: String?) {
        self.init(
            groups: group.map { [$0] } ?? [],
            measure: .histogram(.init(field: field, bounds: bounds)),
            shards: nil,
            date: date
        )
    }
}
