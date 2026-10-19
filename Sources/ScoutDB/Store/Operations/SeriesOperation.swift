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

    func points(field: String?, metric: Metric, groups: [String], in range: Range<Date>) async throws -> [SeriesPoint] {
        let aggregate = try match.aggregate(field: field, metric: metric, groups: groups)

        return try await cells(of: aggregate, groups: groups, in: range)
            .map { key, value in SeriesPoint(group: key.group, date: key.date, value: value) }
            .sorted()
    }

    func averages(field: String, groups: [String], in range: Range<Date>) async throws -> [SeriesPoint] {
        try definition.requireAverageable(field)

        let totaling = try match.aggregate(field: field, metric: .sum, groups: groups)
        let counting = try match.aggregate(field: nil, metric: .sum, groups: groups)

        async let totaled = cells(of: totaling, groups: groups, in: range)
        async let counted = cells(of: counting, groups: groups, in: range)

        let (totals, counts) = try await (totaled, counted)

        return totals.compactMap { key, total in
            guard let count = counts[key], count != 0 else {
                return nil
            }
            return SeriesPoint(group: key.group, date: key.date, value: total / count)
        }
        .sorted()
    }

    private func cells(of aggregate: AggregateDefinition, groups: [String], in range: Range<Date>) async throws
        -> [SeriesPoint.Key: Double]
    {
        let narrowed = try match.groups(narrowedTo: groups)

        let cells = try await VectorReader(
            database: database,
            definition: definition,
            aggregate: aggregate
        )
        .rows(groups: narrowed, in: range)
        .vectorCells(folding: aggregate.fold, in: range)

        return aggregate.measure?.metric == nil ? cells.filter { $0.value != 0 } : cells
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
