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
            let id = SchemaDescriptorEntry.recordID(for: entity)
            guard let record = try await database.fetchRecord(id: id) else {
                throw SchemaError.unknownEntity(entity)
            }
            return try SchemaDescriptorEntry(record: record).definition
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
            fields: definition.activeFields.map {
                EntitySchema.Field(
                    name: $0.name,
                    type: $0.type,
                    required: $0.required == true,
                    payload: $0.storage.isPayload,
                    allowed: $0.allowed,
                    defaultValue: $0.defaultValue,
                    min: $0.min,
                    max: $0.max,
                    pattern: $0.pattern
                )
            }
        )
    }

    /// The entity's schema, or `nil` when nothing is published under the name.
    ///
    /// Only a genuinely missing descriptor maps to `nil`; a fetch that fails
    /// for any other reason — a network drop, a throttle — rethrows, so a
    /// caller deciding between creating and updating never mistakes a
    /// transient failure for a blank slate.
    ///
    public func publishedSchema(for entity: String) async throws -> EntitySchema? {
        do {
            return try await schema(for: entity)
        } catch SchemaError.unknownEntity {
            return nil
        }
    }

    func publish(_ definition: EntityDefinition) async throws {
        try definition.validate()
        let record = try SchemaDescriptorEntry.record(for: definition)
        try await database.modifyRecords(saving: [record], deleting: [])
        cache[definition.entity] = definition
    }
}
