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

    /// Creates a registry backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase) {
        self.database = database
    }

    public func definition(for entity: String) async throws -> EntityDefinition {
        if let cached = cache[entity] {
            return cached
        }
        let entries = try await database.allRecords(matching: metaQuery(entity: entity)).map(SchemaDescriptorEntry.init)
        guard let definition = try latest(of: entries) else {
            throw SchemaError.unknownEntity(entity)
        }
        cache[entity] = definition
        return definition
    }

    public func definitions() -> [EntityDefinition] {
        Array(cache.values)
    }

    @discardableResult public func preload() async throws -> Int {
        let query = ckQuery(
            SchemaDescriptorEntry.recordType,
            filters: [
                ServerFilter(field: "status", op: .equals, value: .string("active"))
            ])
        let entries = try await database.allRecords(matching: query).map(SchemaDescriptorEntry.init)
        for (entity, entries) in Dictionary(grouping: entries, by: \.entity) {
            if let definition = try latest(of: entries) {
                cache[entity] = definition
            }
        }
        return cache.count
    }

    /// Seeds the registry with a definition embedded in the app, without touching
    /// the database — reads and writes can proceed before `publish` lands in SchemaDescriptor.
    ///
    public func register(_ definition: EntityDefinition) throws {
        try definition.validate()
        cache[definition.entity] = definition
    }

    /// Retires an entity: every one of its schema descriptors leaves the active
    /// set, so lookups and preloads stop seeing it and fail with `unknownEntity`.
    ///
    /// Publishing the entity again reactivates it — the descriptor records are
    /// keyed by entity and version, so a republish flips them back to active.
    ///
    public func retire(entity: String) async throws {
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

    public func publish(_ definition: EntityDefinition) async throws {
        try definition.validate()
        let record = CKRecord(recordType: SchemaDescriptorEntry.recordType, recordID: CKRecord.ID(recordName: "\(definition.entity)@\(definition.version)"))
        record["entity"] = definition.entity
        record["entity_version"] = Int64(definition.version)
        record["status"] = "active"
        record["definition"] = try JSONEncoder().encode(definition)
        try await database.write(record: record)
        cache[definition.entity] = definition
    }

    private func latest(of entries: [SchemaDescriptorEntry]) throws -> EntityDefinition? {
        guard let entry = entries.max(by: { $0.version < $1.version }) else { return nil }
        let definition = try JSONDecoder().decode(EntityDefinition.self, from: entry.definition)
        try definition.validate()
        return definition
    }

    private func metaQuery(entity: String) -> CKQuery {
        ckQuery(
            SchemaDescriptorEntry.recordType,
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
