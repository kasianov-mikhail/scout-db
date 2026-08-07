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

    func records(limit: Int? = nil) async throws -> [EntityRecord] {
        if branches.count == 1 {
            return try await records(
                matching: branches[0],
                sort: sort,
                limit: limit
            )
        }

        if let limit, sort.isEmpty {
            var union: [EntityRecord] = []
            for branch in branches {
                union = (union + (try await records(matching: branch, limit: limit))).unique()
                if union.count >= limit {
                    break
                }
            }
            return Array(union.prefix(limit))
        }

        let bounded = rankable
        let results = try await branches.orderedBatches { branch in
            try await self.records(
                matching: branch,
                sort: bounded ? self.sort : [],
                limit: bounded ? limit : nil
            )
        }

        return results.unique().ranked(
            using: sort.map(FieldOrder.init),
            limit: limit
        )
    }

    private func records(matching filters: [ClientFilter], sort: [EntityStore.Sort] = [], limit: Int? = nil)
        async throws -> [EntityRecord]
    {
        if try clientRanked(sort) {
            return try await records(matching: filters).ranked(
                using: sort.map(FieldOrder.init),
                limit: limit
            )
        }

        let plan = try definition.plan(
            matching: filters,
            sort: try definition.serverSort(sort)
        )

        if let limit {
            return try await Array(
                database.scan(
                    matching: plan,
                    limit: limit,
                    using: definition
                )
                .prefix(limit)
            )
        }

        let decoder = EntityDecoder(definition: definition)
        var collected: [EntityRecord] = []

        try await database.pages(matching: plan.query) { page in
            collected += try page.map(decoder.decode).filter(plan.includes)
        }
        return collected
    }

    private func clientRanked(_ sort: [EntityStore.Sort]) throws -> Bool {
        try sort.contains { clause in
            try definition.field(clause.field, at: definition.version).storage.isPayload
        }
    }

    private var rankable: Bool {
        guard sort.count > 0 else {
            return true
        }
        if (try? clientRanked(sort)) == true {
            return true
        }
        return (try? definition.serverSort(sort)) != nil
    }
}

extension FieldOrder {
    init(_ sort: EntityStore.Sort) {
        self.init(key: .field(sort.field), order: sort.order)
    }
}

extension QueryBuilder {
    var read: ReadOperation {
        get async throws {
            try await ReadOperation(
                database: store.database,
                definition: definition,
                branches: alternatives,
                sort: sorts
            )
        }
    }
}
