//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation

struct AggregateDefinition: Equatable, Sendable {
    let name: String
    var groupBy: String?
    var measure: Measure?
    var shards: Int?
    var date: String?

    enum Measure: Equatable, Sendable {
        case sum(String)
        case min(String)
        case max(String)
        case histogram(Histogram)
    }

    var metricKind: Metric? {
        switch measure {
        case .sum:
            .sum
        case .min:
            .min
        case .max:
            .max
        case .histogram, nil:
            nil
        }
    }

    var metricField: String? {
        switch measure {
        case .sum(let field), .min(let field), .max(let field):
            field
        case .histogram, nil:
            nil
        }
    }

    var histogram: Histogram? {
        guard case .histogram(let histogram) = measure else {
            return nil
        }
        return histogram
    }

    var fold: Metric {
        metricKind ?? .sum
    }
}

extension [AggregateDefinition] {
    func covering(_ field: String?, folding metric: Metric) -> AggregateDefinition? {
        first {
            $0.histogram == nil && $0.metricField == field
                && (field == nil || $0.metricKind == metric.storage)
        }
    }
}

extension AggregateDefinition {
    init(
        metric: Metric? = nil, of field: String? = nil, by group: String? = nil, at date: String? = nil,
        shards: Int? = nil
    ) {
        let parts = [
            metric?.label,
            field,
            group.map { "by_\($0)" },
            date.map { "at_\($0)" },
        ]
        .compactMap(\.self)

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

        self.init(
            name: parts.isEmpty ? "by_all" : parts.joined(separator: "_"),
            groupBy: group,
            measure: measure,
            shards: shards,
            date: date
        )
    }

    init(histogramOf field: String, bounds: [Double], at date: String? = nil) {
        self.init(
            name: ["histogram_\(field)", date.map { "at_\($0)" }].compactMap(\.self).joined(separator: "_"),
            measure: .histogram(Histogram(field: field, bounds: bounds)),
            date: date
        )
    }
}
