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
        guard let aggregate = query.foldPlan(in: definition, folding: kind, of: field) else {
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
            let definition = try await store.registry.definition(for: entity)

            guard definition.aggregates?.isEmpty == false, var query = FilterPlan(branches: alternatives) else {
                return nil
            }

            query.expandRange(in: definition)

            guard query.numericField == nil else {
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
