//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

struct ReadOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let branches: [[ClientFilter]]
    let sort: [EntityStore.Sort]
    let fields: [String]?

    func records(limit: Int? = nil) async throws -> [EntityRecord] {
        if branches.count == 1 {
            return try await records(branch: branches[0], sort: sort, limit: limit)
        }

        if let limit, sort.isEmpty {
            var union: [EntityRecord] = []
            for branch in branches {
                union = (union + (try await records(branch: branch, sort: [], limit: limit))).distinct
                if union.count >= limit {
                    break
                }
            }
            return Array(union.prefix(limit))
        }

        let results = try await branches.orderedBatches { branch in
            try await self.records(branch: branch, sort: self.sort, limit: limit)
        }

        return results.distinct.ranked(
            order: sort.map(FieldOrder.init),
            limit: limit
        )
    }

    private func records(branch: [ClientFilter], sort: [EntityStore.Sort], limit: Int?) async throws -> [EntityRecord] {
        let clientRanked = try sort.contains { clause in
            try definition.field(name: clause.field, version: definition.version).storage.isPayload
        }
        if clientRanked {
            return try await records(branch: branch, sort: [], limit: nil).ranked(
                order: sort.map(FieldOrder.init),
                limit: limit
            )
        }

        let plan = try definition.plan(
            filters: branch,
            sort: try definition.serverSort(sort: sort),
            fields: fields.map { $0 + self.sort.map(\.field) }
        )

        if let limit {
            return try await Array(
                database.scan(
                    plan: plan,
                    limit: limit,
                    definition: definition
                )
                .prefix(limit)
            )
        }

        let decoder = EntityDecoder(definition: definition)
        var collected: [EntityRecord] = []

        try await database.pages(plan: plan) { page in
            collected += try page.map(decoder.decode).filter(plan.includes)
        }
        return collected
    }
}

extension FieldOrder {
    init(sort: EntityStore.Sort) {
        self.init(key: .field(name: sort.field), order: sort.order)
    }
}

extension QueryBuilder {
    var read: ReadOperation {
        get async throws {
            try await ReadOperation(
                database: store.database,
                definition: definition,
                branches: alternatives,
                sort: sorts,
                fields: selection
            )
        }
    }
}
