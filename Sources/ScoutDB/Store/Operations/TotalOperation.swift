//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct TotalOperation {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let branches: [[ClientFilter]]

    func rows(aggregate: String, group: String? = nil) async throws -> [AggregateTotal] {
        guard let declared = definition.aggregate(named: aggregate) else {
            throw SchemaError.unknownField(aggregate)
        }

        let records = try await database.allRecords(
            matching: CKQuery(
                gridOf: definition.entity,
                aggregate: aggregate,
                group: group
            )
        )

        let rows = records.gridRows(folding: declared.metricKind) { row in
            row.count != 0 || row.value != nil
        }

        return rows.map { key, fold in
            AggregateTotal(group: key, count: fold.count, value: fold.value)
        }
        .sorted()
    }

    func rows(field: String?, metric: Metric, group: String?) async throws -> [AggregateTotal] {
        guard let aggregate = definition.aggregate(grouping: group, folding: field, as: metric) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(entity: definition.entity, grouping: group, folding: field)
            )
        }

        return try await rows(aggregate: aggregate.name, group: try narrowing(to: group))
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
            TotalOperation(
                database: store.database,
                definition: try await store.registry.definition(for: entity),
                branches: alternatives
            )
        }
    }
}
