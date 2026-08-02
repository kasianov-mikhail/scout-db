//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct ReadOperation: Sendable {
    let database: any CloudDatabase
    let entity: String
    let sort: [EntityStore.Sort]
    let limit: Int?
    let definition: EntityDefinition
    let coder: EntityCoder

    init(store: EntityStore, entity: String, sort: [EntityStore.Sort] = [], limit: Int? = nil) async throws {
        self.database = store.database
        self.entity = entity
        self.sort = sort
        self.limit = limit
        self.definition = try await store.registry.definition(for: entity)
        self.coder = EntityCoder(definition: definition)
    }

    func read(any branches: [[Filter]] = [[]]) async throws -> [EntityRecord] {
        if branches.count == 1 {
            return try await records(matching: branches[0], sort: sort, limit: limit)
        }
        if let limit, sort.isEmpty {
            var seen: Set<String> = []
            var union: [EntityRecord] = []
            for branch in branches {
                let page: [EntityRecord] = try await records(matching: branch, limit: limit)
                for record in page where seen.insert(record.uuid).inserted {
                    union.append(record)
                    if union.count == limit {
                        return union
                    }
                }
            }
            return union
        }
        let bounded = rankable
        let results = try await branches.orderedBatches { branch in
            try await self.records(
                matching: branch,
                sort: bounded ? self.sort : [],
                limit: bounded ? self.limit : nil
            )
        }
        var seen: Set<String> = []
        let union = results.filter { seen.insert($0.uuid).inserted }
        guard sort.count > 0 else {
            return union
        }
        let ranked = union.sorted(using: sort.map(FieldOrder.init))
        guard let limit else {
            return ranked
        }
        return Array(ranked.prefix(limit))
    }

    private func records(matching filters: [Filter], sort: [EntityStore.Sort] = [], limit: Int? = nil)
        async throws -> [EntityRecord]
    {
        if try clientRanked(sort) {
            let ranked = try await records(matching: filters)
                .sorted(using: sort.map(FieldOrder.init))
            guard let limit else {
                return ranked
            }
            return Array(ranked.prefix(limit))
        }
        let query = CKQuery(
            recordType: "Entity",
            filters: try definition.serverFilters(filters),
            sort: try definition.serverSort(sort)
        )

        let matching = try definition.clientFilters(filters)
        let included = { (record: EntityRecord) in matching.allSatisfy { $0.matches(record) ?? false } }

        if let limit {
            return Array(
                try await database.scan(
                    matching: query,
                    limit: limit,
                    using: definition,
                    where: included
                )
                .prefix(limit)
            )
        }

        var collected: [EntityRecord] = []
        try await database.forEachPage(matching: query) { page in
            collected += try page.map { try coder.decode($0) }.filter(included)
        }
        return collected
    }

    private func clientRanked(_ sort: [EntityStore.Sort]) throws -> Bool {
        try sort.contains { clause in
            guard let field = definition.field(named: clause.field, at: definition.version) else {
                throw SchemaError.unknownField(clause.field)
            }
            guard case .payload = field.storage else {
                return false
            }
            return true
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
        self.init(key: .field(sort.field), order: sort.ascending ? .forward : .reverse)
    }
}
