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
            let entries = try await database.allRecords(matching: CKQuery(activeSchemasOf: entity)).map(
                SchemaDescriptorEntry.init
            )
            guard let definition = try entries.latest else {
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

    /// The entity's schema as a caller sees it: the fields a write may carry
    /// and the rules over them, without the storage the library keeps to
    /// itself.
    public func schema(for entity: String) async throws -> EntitySchema {
        let definition = try await definition(for: entity)
        return EntitySchema(
            entity: definition.entity,
            fields: definition.fields(at: definition.version).map {
                EntitySchema.Field(
                    name: $0.name,
                    type: $0.type,
                    required: $0.required == true,
                    payload: $0.storage == .payload,
                    allowed: $0.allowed,
                    defaultValue: $0.defaultValue,
                    min: $0.min,
                    max: $0.max,
                    pattern: $0.pattern
                )
            },
            unique: definition.unique
        )
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
        try await database.modifyRecords(saving: [record], deleting: [])
        cache[definition.entity] = definition
    }
}
