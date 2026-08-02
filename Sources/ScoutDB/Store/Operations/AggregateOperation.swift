//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

struct AggregateOperation {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let branches: [[ClientFilter]]
    let field: String

    func value(metric: Metric) async throws -> Double? {
        let target = try definition.field(field)

        guard [.int, .double].contains(target.type) else {
            throw SchemaError.unsupportedQuery(.nonNumericField(field))
        }

        if metric != .average || target.alwaysPresent {
            let operation = FoldOperation(
                database: database,
                definition: definition,
                branches: branches
            )

            if let folded = try await operation?.fold(of: field, folding: metric) {
                return metric.apply(
                    values: [folded.value].compactMap(\.self),
                    count: folded.count
                )
            }
        }

        let scalars = try await ReadOperation(
            database: database,
            definition: definition,
            sort: [],
            limit: nil
        )
        .read(branches: branches)
        .compactMap(\.values[field]?.scalar)

        return metric.apply(
            values: scalars,
            count: scalars.count
        )
    }
}

extension AggregateOperation {
    init(query: QueryBuilder, field: String) async throws {
        self.init(
            database: query.store.database,
            definition: try await query.definition,
            branches: query.alternatives,
            field: field
        )
    }
}

extension QueryBuilder {
    var definition: EntityDefinition {
        get async throws {
            try await store.registry.definition(for: entity)
        }
    }
}
