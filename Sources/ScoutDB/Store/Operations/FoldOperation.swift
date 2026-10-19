//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct FoldOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let query: FilterPlan

    func cell(field: String?, kind: Metric) async throws -> Double? {
        let covering = query.groupField.map { group in
            definition.aggregates.filter { $0.groupBy == group }
        }

        guard let aggregate = (covering ?? definition.aggregates).covering(field: field, metric: kind) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(entity: definition.entity, grouping: query.groupField, folding: field)
            )
        }

        let rows = try await VectorReader(
            database: database,
            definition: definition,
            aggregate: aggregate
        )
        .rows(groups: query.serverGroups)
        .filter { query.groupField == nil || query.groupKeys.contains($0.group) }
        .vectorRows(kind: kind.storage)

        return kind.storage.fold(values: rows.values)
    }
}

extension FilterPlan {
    fileprivate var serverGroups: [String]? {
        groupField == nil || groupKeys.isEmpty ? nil : Array(groupKeys)
    }
}

extension QueryBuilder {
    var fold: FoldOperation? {
        get async throws {
            let definition = try await self.definition

            guard !definition.aggregates.isEmpty, var query = FilterPlan(branches: alternatives) else {
                return nil
            }

            query.expandRange(definition: definition)

            guard query.bounds == nil else {
                return nil
            }

            return FoldOperation(
                database: store.database,
                definition: definition,
                query: query
            )
        }
    }
}
