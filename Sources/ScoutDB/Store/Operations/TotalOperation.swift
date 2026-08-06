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

    func rows(aggregate: String, group: String? = nil) async throws -> [AggregateTotal] {
        try await folds(aggregate: aggregate, group: group)
            .map { AggregateTotal(group: $0.key, value: $0.value) }
            .sorted()
    }

    func rows(field: String?, metric: Metric, group: String?) async throws -> [AggregateTotal] {
        let narrowed = try narrowing(to: group)

        guard metric == .average, let field else {
            let aggregate = try covering(field: field, metric: metric, group: group)
            return try await rows(aggregate: aggregate.name, group: narrowed)
        }

        let summing = try covering(field: field, metric: .sum, group: group)
        let counting = try covering(field: nil, metric: .sum, group: group)

        async let summed = folds(aggregate: summing.name, group: narrowed)
        async let counted = folds(aggregate: counting.name, group: narrowed)

        let (sums, counts) = try await (summed, counted)

        return sums.compactMap { key, sum in
            guard let count = counts[key], count != 0 else {
                return nil
            }
            return AggregateTotal(group: key, value: sum / count)
        }
        .sorted()
    }

    private func folds(aggregate: String, group: String?) async throws -> [String: Double] {
        guard let declared = definition.aggregates.first(where: { $0.name == aggregate }) else {
            throw SchemaError.unknownField(aggregate)
        }

        let rows = try await VectorReader(database: database, definition: definition, aggregate: declared)
            .rows(groups: group.map { [$0] })
            .vectorRows(folding: declared.fold)

        return declared.measure?.metric == nil ? rows.filter { $0.value != 0 } : rows
    }

    private func covering(field: String?, metric: Metric, group: String?) throws -> AggregateDefinition {
        let grouping = definition.aggregates.filter { $0.groupBy == group }

        guard let aggregate = grouping.covering(field, folding: metric) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(entity: definition.entity, grouping: group, folding: field)
            )
        }
        return aggregate
    }

    private func narrowing(to group: String?) throws -> String? {
        guard branches.count == 1 else {
            throw SchemaError.unsupportedQuery(.disjunctionUnsupported)
        }

        var narrowed: String?
        for filter in branches[0] {
            guard let group, filter.field == group, filter.op == .equals else {
                throw SchemaError.unsupportedQuery(.equalityOnly(group: group))
            }
            narrowed = filter.value.canonical
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
