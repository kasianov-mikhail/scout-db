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

    func cell(of field: String?, folding kind: Metric) async throws -> Double? {
        let covering = query.groupField.map { group in
            definition.aggregates.filter { $0.groupBy == group }
        }

        guard let aggregate = (covering ?? definition.aggregates).covering(field, folding: kind) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(entity: definition.entity, grouping: query.groupField, folding: field)
            )
        }

        let rows = try await aggregate.rows(
            from: database,
            of: definition.entity,
            groups: query.serverGroups,
            folding: kind.storage
        ) { group in
            query.groupField == nil || query.groupKeys.contains(group)
        }

        return kind.storage.fold(rows.values)
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

            query.expandRange(in: definition)

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
