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

    func cell(of field: String?, folding kind: Metric) async throws -> GridFold? {
        let aggregates = definition.aggregates.filter { $0.histogram == nil }
        let covering = query.groupField.map { group in aggregates.filter { $0.groupBy == group } } ?? aggregates
        let folding = field.map { field in
            covering.first { $0.metricKind == kind.storage && $0.metricField == field }
        }

        guard let aggregate = folding ?? covering.first else {
            return nil
        }

        let records = try await database.allRecords(
            matching: CKQuery(
                gridOf: definition.entity,
                aggregate: aggregate.name,
                group: query.serverGroup
            )
        )

        let rows = records.gridRows(folding: kind) { row in
            guard row.count > 0 else {
                return false
            }
            return query.groupField == nil || query.groupKeys.contains(row.group)
        }

        return rows.values.reduce(GridFold.empty) { $0.merging($1, folding: kind) }
    }
}

extension FilterPlan {
    fileprivate var serverGroup: String? {
        groupKeys.count == 1 ? groupKeys.first : nil
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
