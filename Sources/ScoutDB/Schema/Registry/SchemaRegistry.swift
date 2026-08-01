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
    public init(database: any CloudDatabase) {
        self.database = database
    }

    func definition(for entity: String) async throws -> EntityDefinition {
        if let cached = cache[entity] {
            return cached
        }
        if let inFlight = loading[entity] {
            return try await inFlight.value
        }

        let task = Task { () throws -> EntityDefinition in
            let entries = try await database.allRecords(matching: metaQuery(entity: entity)).map(
                SchemaDescriptorEntry.init
            )
            guard let definition = try latest(of: entries) else {
                throw SchemaError.unknownEntity(entity)
            }
            return definition
        }

        loading[entity] = task
        defer {
            loading[entity] = nil
        }

        let definition = try await task.value
        cache[entity] = definition
        return definition
    }

    func alwaysPresent(_ field: String, entity: String) async throws -> Bool {
        let definition = try await definition(for: entity)

        guard let target = definition.field(named: field, at: definition.version) else {
            return false
        }

        return target.alwaysPresent
    }

    /// The entity's schema as a caller sees it: the fields a write may carry
    /// and the rules over them, without the storage the library keeps to
    /// itself.
    public func schema(for entity: String) async throws -> EntitySchema {
        EntitySchema(try await definition(for: entity))
    }

    /// The schemas of every entity the registry has loaded so far.
    public func schemas() -> [EntitySchema] {
        cache.values.map(EntitySchema.init)
    }

    func publish(_ definition: EntityDefinition) async throws {
        try definition.validate()
        let record = CKRecord(
            recordType: SchemaDescriptorEntry.recordType,
            recordID: CKRecord.ID(recordName: "\(definition.entity)@\(definition.version)")
        )
        record["entity"] = definition.entity
        record["entity_version"] = Int64(definition.version)
        record["status"] = "active"
        record["definition"] = try JSONEncoder().encode(definition)
        try await database.write(records: [record])
        cache[definition.entity] = definition
    }

    private func latest(of entries: [SchemaDescriptorEntry]) throws -> EntityDefinition? {
        guard let entry = entries.max() else {
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
            ]
        )
    }
}

private struct SchemaDescriptorEntry {
    static let recordType = "SchemaDescriptor"

    let entity: String
    let version: Int
    let definition: Data

    init(record: CKRecord) throws {
        guard let entity = record["entity"] as? String, let version = record["entity_version"] as? Int64 else {
            throw SchemaError.invalidDefinition("Malformed SchemaDescriptor record '\(record.recordID.recordName)'")
        }
        guard let definition = record["definition"] as? Data else {
            throw SchemaError.invalidDefinition("Malformed SchemaDescriptor record '\(record.recordID.recordName)'")
        }
        self.entity = entity
        self.version = Int(version)
        self.definition = definition
    }
}

extension SchemaDescriptorEntry: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.version < rhs.version
    }
}
