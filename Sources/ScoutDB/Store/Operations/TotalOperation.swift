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
    let aggregate: String
    let group: String?

    func totals() async throws -> [AggregateTotal] {
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
}

extension TotalOperation {
    init(store: EntityStore, entity: String, aggregate: String, group: String? = nil) async throws {
        self.init(
            database: store.database,
            definition: try await store.registry.definition(for: entity),
            aggregate: aggregate,
            group: group
        )
    }

    init(query: QueryBuilder, field: String?, metric: Metric, group: String?) async throws {
        let store = query.store
        let definition = try await query.definition

        guard let aggregate = definition.aggregate(grouping: group, folding: field, as: metric) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(entity: query.entity, grouping: group, folding: field)
            )
        }

        self.init(
            database: store.database,
            definition: definition,
            aggregate: aggregate.name,
            group: try query.narrowing(to: group)
        )
    }
}

extension QueryBuilder {
    fileprivate func narrowing(to group: String?) throws -> String? {
        guard let flat else {
            throw SchemaError.unsupportedQuery(.disjunctionUnsupported)
        }

        var narrowed: String?
        for filter in flat {
            guard let group, filter.field == group, filter.op == .equals else {
                throw SchemaError.unsupportedQuery(.equalityOnly(group: group))
            }
            narrowed = filter.value.canonical
        }
        return narrowed
    }
}
