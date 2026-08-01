//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func read(entity: String, filters: [Filter] = [], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil)
        async throws -> [EntityRecord]
    {
        let definition = try await registry.definition(for: entity)
        if try clientRanked(sort, using: definition) {
            let projection = fields.map { $0 + sort.map(\.field) }
            let ranked = try await read(entity: entity, filters: filters, fields: projection)
                .sorted { Self.ordered($0, $1, by: sort) }
            guard let limit else {
                return ranked
            }
            return Array(ranked.prefix(limit))
        }
        let (query, included) = try liveQuery(
            filters,
            entity: entity,
            sort: try serverSort(sort, using: definition),
            using: definition
        )
        let keys = try fields.map { try desiredKeys($0 + filters.map(\.field), using: definition) }
        if let limit {
            return Array(
                try await boundedRecords(
                    matching: query,
                    desiredKeys: keys,
                    limit: limit,
                    using: definition,
                    where: included
                ).prefix(limit)
            )
        }
        return try decode(try await database.allRecords(matching: query, desiredKeys: keys), using: definition).filter(
            included
        )
    }

    func read(entity: String, any branches: [[Filter]], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil)
        async throws -> [EntityRecord]
    {
        if branches.count == 1 {
            return try await read(entity: entity, filters: branches[0], sort: sort, fields: fields, limit: limit)
        }
        let branchFields = fields.map { $0 + sort.map(\.field) }
        if let limit, sort.isEmpty {
            var seen: Set<String> = []
            var union: [EntityRecord] = []
            for branch in branches {
                let page: [EntityRecord] = try await read(
                    entity: entity,
                    filters: branch,
                    fields: branchFields,
                    limit: limit
                )
                for record in page where seen.insert(record.uuid).inserted {
                    union.append(record)
                    if union.count == limit {
                        return union
                    }
                }
            }
            return union
        }
        let bounded = try await rankable(sort, entity: entity)
        let results = try await withThrowingTaskGroup(of: (Int, [EntityRecord]).self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask {
                    (
                        index,
                        try await self.read(
                            entity: entity,
                            filters: branch,
                            sort: bounded ? sort : [],
                            fields: branchFields,
                            limit: bounded ? limit : nil
                        )
                    )
                }
            }
            var collected: [Int: [EntityRecord]] = [:]
            for try await (index, records) in group {
                collected[index] = records
            }
            return collected.sorted { $0.key < $1.key }.flatMap(\.value)
        }
        var seen: Set<String> = []
        let union = results.filter { seen.insert($0.uuid).inserted }
        guard sort.count > 0 else {
            return union
        }
        let ranked = union.sorted { Self.ordered($0, $1, by: sort) }
        guard let limit else {
            return ranked
        }
        return Array(ranked.prefix(limit))
    }

    private func rankable(_ sort: [Sort], entity: String) async throws -> Bool {
        guard sort.count > 0 else {
            return true
        }
        let definition = try await registry.definition(for: entity)
        if (try? clientRanked(sort, using: definition)) == true {
            return true
        }
        return (try? serverSort(sort, using: definition)) != nil
    }

    private func clientRanked(_ sort: [Sort], using definition: EntityDefinition) throws -> Bool {
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
}
