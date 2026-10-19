//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct TotalOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let branches: [[ClientFilter]]

    func rows(field: String?, metric: Metric, groups: [String]) async throws -> [AggregateTotal] {
        let aggregate = try match.aggregate(field: field, metric: metric, groups: groups)

        return try await folds(of: aggregate, groups: groups)
            .map(AggregateTotal.init)
            .sorted()
    }

    func averages(field: String, groups: [String]) async throws -> [AggregateTotal] {
        try definition.requireAverageable(field)

        let totaling = try match.aggregate(field: field, metric: .sum, groups: groups)
        let counting = try match.aggregate(field: nil, metric: .sum, groups: groups)

        async let totaled = folds(of: totaling, groups: groups)
        async let counted = folds(of: counting, groups: groups)

        let (totals, counts) = try await (totaled, counted)

        return totals.compactMap { key, total in
            guard let count = counts[key], count != 0 else {
                return nil
            }
            return AggregateTotal(group: key, value: total / count)
        }
        .sorted()
    }

    private func folds(of aggregate: AggregateDefinition, groups: [String]) async throws -> [String: Double] {
        let narrowed = try match.groups(narrowedTo: groups)

        let rows = try await VectorReader(
            database: database,
            definition: definition,
            aggregate: aggregate
        )
        .rows(groups: narrowed)
        .vectorRows(folding: aggregate.fold)

        return aggregate.measure?.metric == nil ? rows.filter { $0.value != 0 } : rows
    }

    private var match: AggregateMatch {
        AggregateMatch(definition: definition, branches: branches)
    }
}

extension QueryBuilder {
    var total: TotalOperation {
        get async throws {
            try await TotalOperation(
                database: store.database,
                definition: definition,
                branches: alternatives
            )
        }
    }
}
