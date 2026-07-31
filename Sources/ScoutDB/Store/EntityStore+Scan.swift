//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    func liveQuery(_ filters: [Filter], entity: String, sort: [ServerSort] = [], using definition: EntityDefinition)
        throws
        -> (query: CKQuery, included: (EntityRecord) -> Bool)
    {
        let (server, client) = try split(filters, entity: entity, using: definition)
        let matchers = try Self.matchers(for: client)
        return (
            CKQuery(recordType: "Entity", filters: server, sort: sort),
            { record in matchers.allSatisfy { $0(record) } }
        )
    }

    func desiredKeys(_ fields: [String], using definition: EntityDefinition) throws -> [String] {
        var keys = EntityCoder.envelopeKeys
        for name in Set(fields) {
            guard let field = definition.field(named: name, at: definition.version) else {
                throw SchemaError.unknownField(name)
            }
            switch field.storage {
            case .slot(_, let slot):
                keys.append(slot)
            case .payload:
                if !keys.contains("payload") {
                    keys.append("payload")
                }
            }
        }
        return keys
    }

    func boundedRecords(
        matching query: CKQuery, desiredKeys: [String]?, limit: Int, using definition: EntityDefinition, where included: (EntityRecord) -> Bool
    ) async throws -> [EntityRecord] {
        var collected: [EntityRecord] = []
        var page = Self.cappedPage(limit == Int.max ? limit : limit + 1)
        var (batch, token) = try await database.records(matching: query, desiredKeys: desiredKeys, resultsLimit: page)
        while true {
            collected += try decode(batch.map { try $0.1.get() }, using: definition).filter(included)
            guard collected.count < limit, let cursor = token else {
                break
            }
            page = page < Int.max / 2 ? Self.cappedPage(page * 2) : page
            (batch, token) = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: page)
        }
        return collected
    }

    private static func cappedPage(_ rows: Int) -> Int {
        let maximum = CKQueryOperation.maximumResults
        return maximum > 0 ? Swift.min(rows, maximum) : rows
    }

    func forEachPage(matching query: CKQuery, desiredKeys: [String]? = nil, using definition: EntityDefinition, _ body: ([EntityRecord]) async throws -> Void)
        async throws
    {
        try await database.forEachPage(matching: query, desiredKeys: desiredKeys) { page in
            try await body(try decode(page, using: definition))
        }
    }

    func forEachPage(entity: String, fields: [String]? = nil, _ body: ([EntityRecord]) async throws -> Void) async throws {
        let definition = try await registry.definition(for: entity)
        let (query, included) = try liveQuery([], entity: entity, using: definition)
        let keys = try fields.map { try desiredKeys($0, using: definition) }
        try await forEachPage(matching: query, desiredKeys: keys, using: definition) { page in
            try await body(page.filter(included))
        }
    }
}
