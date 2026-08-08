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

    func points(field: String?, metric: Metric, group: String?, in range: Range<Date>) async throws -> [SeriesPoint] {
        let aggregate = try match.aggregate(field: field, metric: metric, group: group)

        return try await cells(of: aggregate, group: group, in: range)
            .map(SeriesPoint.init)
            .sorted()
    }

    func averages(field: String, group: String?, in range: Range<Date>) async throws -> [SeriesPoint] {
        try definition.requireAverageable(field)

        let totaling = try match.aggregate(field: field, metric: .sum, group: group)
        let counting = try match.aggregate(field: nil, metric: .sum, group: group)

        async let totaled = cells(of: totaling, group: group, in: range)
        async let counted = cells(of: counting, group: group, in: range)

        let (totals, counts) = try await (totaled, counted)

        return totals.compactMap { cell, total in
            guard let count = counts[cell], count != 0 else {
                return nil
            }
            return SeriesPoint(cell, total / count)
        }
        .sorted()
    }

    private func cells(of aggregate: AggregateDefinition, group: String?, in range: Range<Date>) async throws
        -> [SeriesCell: Double]
    {
        let narrowed = try match.groups(narrowedTo: group)

        let cells = try await VectorReader(
            database: database,
            entity: definition.entity,
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

extension SeriesPoint {
    fileprivate init(_ cell: SeriesCell, _ value: Double) {
        self.init(group: cell.group, date: cell.date, value: value)
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
