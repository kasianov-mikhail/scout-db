//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateDefinition: Codable, Equatable, Sendable {
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
}

extension AggregateDefinition {
    init(metric: Metric? = nil, of field: String? = nil, by group: String? = nil, shards: Int? = nil) {
        let parts = [metric?.label, field, group.map { "by_\($0)" }].compactMap(\.self)

        self.init(
            name: parts.isEmpty ? "by_all" : parts.joined(separator: "_"),
            groupBy: group,
            sum: metric?.storage == .sum ? field : nil,
            min: metric?.storage == .min ? field : nil,
            max: metric?.storage == .max ? field : nil,
            shards: shards
        )
    }
}
