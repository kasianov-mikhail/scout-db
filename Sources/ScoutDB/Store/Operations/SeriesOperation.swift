//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct SeriesOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let branches: [[ClientFilter]]

    func points(field: String?, metric: Metric, group: String?, range: Range<Date>) async throws -> [SeriesPoint] {
        let vectors = try reader(field: field, metric: metric, group: group)
        let groups = try match.groups(group: group)

        return try await vectors.cells(groups: groups, range: range)
            .map { key, value in SeriesPoint(group: key.group, date: key.date, value: value) }
            .sorted()
    }

    func averages(field: String, group: String?, range: Range<Date>) async throws -> [SeriesPoint] {
        try definition.requireAverageable(name: field)

        let totaling = try reader(field: field, metric: .sum, group: group)
        let counting = try reader(field: nil, metric: .sum, group: group)
        let groups = try match.groups(group: group)

        async let totaled = totaling.cells(groups: groups, range: range)
        async let counted = counting.cells(groups: groups, range: range)

        let (totals, counts) = try await (totaled, counted)

        return totals.compactMap { key, total in
            guard let count = counts[key], count != 0 else {
                return nil
            }
            return SeriesPoint(group: key.group, date: key.date, value: total / count)
        }
        .sorted()
    }

    private func reader(field: String?, metric: Metric, group: String?) throws -> VectorReader {
        VectorReader(
            database: database,
            definition: definition,
            aggregate: try match.aggregate(field: field, metric: metric, group: group)
        )
    }

    private var match: AggregateMatch {
        AggregateMatch(definition: definition, branches: branches)
    }
}

extension QueryBuilder {
    var cells: SeriesOperation {
        get async throws {
            try await SeriesOperation(
                database: store.database,
                definition: definition,
                branches: alternatives
            )
        }
    }
}
