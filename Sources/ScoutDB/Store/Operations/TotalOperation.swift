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

    func rows(field: String?, metric: Metric, group: String?) async throws -> [AggregateTotal] {
        let aggregate = try covering(field: field, metric: metric, group: group)

        return try await folds(of: aggregate, group: group)
            .map(AggregateTotal.init)
            .sorted()
    }

    func averages(field: String?, group: String?) async throws -> [AggregateTotal] {
        let totaling = try covering(field: field, metric: .sum, group: group)
        let counting = try covering(field: nil, metric: .sum, group: group)

        async let totaled = folds(of: totaling, group: group)
        async let counted = folds(of: counting, group: group)

        let (totals, counts) = try await (totaled, counted)

        return totals.compactMap { key, total in
            guard let count = counts[key], count != 0 else {
                return nil
            }
            return AggregateTotal(group: key, value: total / count)
        }
        .sorted()
    }

    private func folds(of aggregate: AggregateDefinition, group: String?) async throws -> [String: Double] {
        let narrowed = try narrowing(to: group)

        let rows = try await VectorReader(
            database: database,
            definition: definition,
            aggregate: aggregate
        )
        .rows(groups: narrowed)
        .vectorRows(folding: aggregate.fold, where: nil)

        return aggregate.measure?.metric == nil ? rows.filter { $0.value != 0 } : rows
    }

    private func covering(field: String?, metric: Metric, group: String?) throws -> AggregateDefinition {
        let grouping = definition.aggregates.filter { $0.groupBy == group }

        guard let aggregate = grouping.covering(field, folding: metric) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(
                    entity: definition.entity,
                    grouping: group,
                    folding: field
                )
            )
        }
        return aggregate
    }

    private func narrowing(to group: String?) throws -> [String]? {
        guard branches.count == 1 else {
            throw SchemaError.unsupportedQuery(.disjunctionUnsupported)
        }

        var narrowed: [String]?
        for filter in branches[0] {
            guard let group, filter.field == group, filter.op == .equals else {
                throw SchemaError.unsupportedQuery(
                    .equalityOnly(group: group)
                )
            }
            let key = filter.value.canonical
            narrowed = narrowed.map { $0.contains(key) ? [key] : [] } ?? [key]
        }
        return narrowed
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
