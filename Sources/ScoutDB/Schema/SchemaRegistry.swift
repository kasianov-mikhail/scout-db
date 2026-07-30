//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public actor SchemaRegistry {
    private let database: any CloudDatabase
    private var cache: [String: EntityDefinition] = [:]
    private var loading: [String: Task<EntityDefinition, any Error>] = [:]

    /// Creates a registry backed by any `CloudDatabase` implementation.
    ///
    /// The entities the library keeps for itself — the transaction envelope and
    /// the revision log — are seeded from the definitions built into it, so
    /// they need no publishing of their own.
    ///
    public init(database: any CloudDatabase) {
        self.database = database

        for definition in Self.builtIns {
            cache[definition.entity] = definition
        }
    }

    fileprivate static var builtIns: [EntityDefinition] {
        [.transaction, .revision]
    }

    fileprivate static let builtInEntities: Set<String> = [
        EntityStore.transactionEntity,
        EntityStore.revisionEntity,
    ]

    func definition(for entity: String) async throws -> EntityDefinition {
        if let cached = cache[entity] {
            return cached
        }
        if let inFlight = loading[entity] {
            return try await inFlight.value
        }
        let task = Task { () throws -> EntityDefinition in
            let entries = try await database.allRecords(matching: metaQuery(entity: entity)).map(SchemaDescriptorEntry.init)
            guard let definition = try latest(of: entries) else {
                throw SchemaError.unknownEntity(entity)
            }
            return definition
        }
        loading[entity] = task
        defer { loading[entity] = nil }
        let definition = try await task.value
        cache[entity] = definition
        return definition
    }

    func definitions() -> [EntityDefinition] {
        cache.values.filter { !Self.builtInEntities.contains($0.entity) }
    }

    /// The entity's schema as a caller sees it: the fields a write may carry
    /// and the rules over them, without the storage the library keeps to
    /// itself.
    public func schema(for entity: String) async throws -> EntitySchema {
        EntitySchema(try await definition(for: entity))
    }

    /// The schemas of every entity loaded so far, which `preload()` fills in
    /// one query — the library's own entities left out.
    public func schemas() -> [EntitySchema] {
        definitions().map(EntitySchema.init)
    }

    @discardableResult public func preload() async throws -> Int {
        let query = CKQuery(
            recordType: SchemaDescriptorEntry.recordType,
            filters: [
                ServerFilter(field: "status", op: .equals, value: .string("active"))
            ])
        let entries = try await database.allRecords(matching: query).map(SchemaDescriptorEntry.init)
        for (entity, entries) in Dictionary(grouping: entries, by: \.entity) {
            if let definition = try latest(of: entries) {
                cache[entity] = definition
            }
        }
        return definitions().count
    }

    func retire(entity: String) async throws {
        let descriptors = try await database.allRecords(matching: metaQuery(entity: entity))
        guard descriptors.count > 0 else {
            throw SchemaError.unknownEntity(entity)
        }
        for descriptor in descriptors {
            descriptor["status"] = "retired"
        }
        try await database.write(records: descriptors)
        cache[entity] = nil
    }

    func publish(_ definition: EntityDefinition) async throws {
        try definition.validate()
        let record = CKRecord(recordType: SchemaDescriptorEntry.recordType, recordID: CKRecord.ID(recordName: "\(definition.entity)@\(definition.version)"))
        record["entity"] = definition.entity
        record["entity_version"] = Int64(definition.version)
        record["status"] = "active"
        record["definition"] = try JSONEncoder().encode(definition)
        try await database.write(records: [record])
        cache[definition.entity] = definition
    }

    private func latest(of entries: [SchemaDescriptorEntry]) throws -> EntityDefinition? {
        guard let entry = entries.max(by: { $0.version < $1.version }) else {
            return nil
        }
        let definition = try JSONDecoder().decode(EntityDefinition.self, from: entry.definition)
        try definition.validate()
        return definition
    }

    private func metaQuery(entity: String) -> CKQuery {
        CKQuery(
            recordType: SchemaDescriptorEntry.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "status", op: .equals, value: .string("active")),
            ])
    }
}

struct SchemaDescriptorEntry {
    static let recordType = "SchemaDescriptor"

    let entity: String
    let version: Int
    let definition: Data

    init(record: CKRecord) throws {
        guard let entity = record["entity"] as? String, let version = record["entity_version"] as? Int64, let definition = record["definition"] as? Data else {
            throw SchemaError.invalidDefinition("Malformed SchemaDescriptor record '\(record.recordID.recordName)'")
        }
        self.entity = entity
        self.version = Int(version)
        self.definition = definition
    }
}
