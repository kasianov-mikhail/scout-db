//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public actor SchemaRegistry {
    private let database: any RecordReader & RecordWriter
    private var cache: [String: EntityDefinition] = [:]

    public init(database: any RecordReader & RecordWriter) {
        self.database = database
    }

    public func definition(for entity: String) async throws -> EntityDefinition {
        if let cached = cache[entity] {
            return cached
        }
        let entries: [MetaEntry] = try await database.readAll(matching: metaQuery(entity: entity))
        guard let definition = try latest(of: entries) else {
            throw UniversalSchemaError.unknownEntity(entity)
        }
        cache[entity] = definition
        return definition
    }

    public func definition(for entity: String, version: Int) async throws -> EntityDefinition {
        var definition = try await definition(for: entity)
        if definition.version < version {
            cache[entity] = nil
            definition = try await self.definition(for: entity)
        }
        guard definition.version >= version else {
            throw UniversalSchemaError.staleSchema(entity: entity, version: version)
        }
        return definition
    }

    public func definitions() -> [EntityDefinition] {
        Array(cache.values)
    }

    @discardableResult public func preload() async throws -> Int {
        let query = RecordQuery(
            recordType: MetaEntry.self,
            filters: [
                RecordQuery.Filter(field: "status", op: .equals, value: .string("active"))
            ])
        let entries: [MetaEntry] = try await database.readAll(matching: query)
        for (entity, entries) in Dictionary(grouping: entries, by: \.entity) {
            if let definition = try latest(of: entries) {
                cache[entity] = definition
            }
        }
        return cache.count
    }

    public func publish(_ definition: EntityDefinition) async throws {
        try definition.validate()
        var record = Record(recordType: MetaEntry.recordType, recordID: "\(definition.entity)@\(definition.version)")
        record["entity"] = definition.entity
        record["entity_version"] = Int64(definition.version)
        record["status"] = "active"
        record["definition"] = try JSONEncoder().encode(definition)
        try await database.write(record: record)
        cache[definition.entity] = definition
    }

    private func latest(of entries: [MetaEntry]) throws -> EntityDefinition? {
        guard let entry = entries.max(by: { $0.version < $1.version }) else { return nil }
        let definition = try JSONDecoder().decode(EntityDefinition.self, from: entry.definition)
        try definition.validate()
        return definition
    }

    private func metaQuery(entity: String) -> RecordQuery {
        RecordQuery(
            recordType: MetaEntry.self,
            filters: [
                RecordQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                RecordQuery.Filter(field: "status", op: .equals, value: .string("active")),
            ])
    }
}

struct MetaEntry: RecordDecodable {
    static let recordType = "Meta"
    static let sampleRecords: [Record] = []

    static let desiredKeys = [
        "entity",
        "entity_version",
        "definition",
        "status",
    ]

    let entity: String
    let version: Int
    let definition: Data

    init(record: Record) throws {
        guard let entity: String = record["entity"], let version: Int64 = record["entity_version"], let definition: Data = record["definition"] else {
            throw UniversalSchemaError.invalidDefinition("Malformed Meta record '\(record.recordID)'")
        }
        self.entity = entity
        self.version = Int(version)
        self.definition = definition
    }
}
