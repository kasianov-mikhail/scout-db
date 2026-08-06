//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct PercentileOperation {
    let database: any CloudDatabase
    let definition: EntityDefinition

    func value(of field: String, at rank: Double) async throws -> Double? {
        guard (0...1).contains(rank) else {
            throw SchemaError.unsupportedQuery(.rankOutOfRange(rank))
        }

        let declared = definition.aggregates.first { $0.measure?.histogram?.field == field }

        guard let aggregate = declared, let histogram = aggregate.measure?.histogram else {
            throw SchemaError.unsupportedQuery(
                .noHistogram(entity: definition.entity, field: field)
            )
        }

        let records = try await database.allRecords(
            matching: CKQuery(gridOf: definition.entity, aggregate: aggregate.name)
        )

        let rows = records.gridRows(folding: aggregate.fold)
        let counts = histogram.groupKeys.map { rows[$0] ?? 0 }

        return histogram.percentile(rank, over: counts)
    }
}

extension QueryBuilder {
    var percentiles: PercentileOperation {
        get async throws {
            guard alternatives.allSatisfy(\.isEmpty) else {
                throw SchemaError.unsupportedQuery(.filteredHistogram)
            }
            return PercentileOperation(
                database: store.database,
                definition: try await definition
            )
        }
    }
}
