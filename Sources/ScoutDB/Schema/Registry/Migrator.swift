//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public struct Migrator: Sendable {
    let database: any CloudDatabase
    let registry: SchemaRegistry

    /// Creates a migrator backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase, registry: SchemaRegistry) {
        self.database = database
        self.registry = registry
    }

    @discardableResult public func backfill(entity: String, transform: (inout EntityRecord) throws -> Void = { _ in })
        async throws -> Int
    {
        try await backfill(entity: entity) { record, _ in try transform(&record) }
    }

    @discardableResult public func rename(entity: String, from: String, to: String) async throws -> Int {
        let definition = try await registry.definition(for: entity)

        guard definition.fieldsByName(at: definition.version)[to] != nil else {
            throw SchemaError.unknownField(to)
        }

        return try await backfill(entity: entity) { record, previous in
            record.values[to] = record.values[to] ?? previous.values[from]
        }
    }

    @discardableResult public func backfill(
        entity: String, transform: (inout EntityRecord, _ previous: EntityRecord) throws -> Void
    ) async throws -> Int {
        let definition = try await registry.definition(for: entity)

        let query = CKQuery(
            recordType: "Entity",
            filters: [
                CKQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                CKQuery.Filter(field: "schema_version", op: .lessThan, value: .int(Int64(definition.version))),
            ]
        )

        let encoder = EntityEncoder(definition: definition)
        let decoder = EntityDecoder(definition: definition)
        var migrated = 0

        try await database.forEachPage(matching: query) { page in
            let rewritten = try page.map { record in
                let previous = try decoder.decode(record)
                var entityRecord = EntityRecord(
                    entity: entity,
                    uuid: previous.uuid,
                    schemaVersion: definition.version,
                    values: definition.rekey(previous)
                )
                try transform(&entityRecord, previous)
                entityRecord.values = try definition.resolve(entityRecord.values, at: entityRecord.schemaVersion)
                return try encoder.encode(entityRecord, into: record)
            }

            guard rewritten.count > 0 else {
                return
            }
            for chunk in rewritten.chunked(into: maxBatchSize) {
                try await database.modifyRecords(saving: chunk, deleting: [])
            }

            migrated += rewritten.count
        }

        return migrated
    }

    @discardableResult public func backfill(aggregate name: String, entity: String, batchSize: Int = 400) async throws
        -> Int
    {
        let definition = try await registry.definition(for: entity)

        guard let aggregate = definition.aggregate(named: name) else {
            throw SchemaError.unknownField(name)
        }

        try await database.forEachPage(matching: CKQuery(gridOf: entity, aggregate: name)) { page in
            for chunk in page.map(\.recordID).chunked(into: batchSize) {
                try await database.modifyRecords(saving: [], deleting: chunk)
            }
        }

        var scoped = definition
        scoped.aggregates = [aggregate]

        let decoder = EntityDecoder(definition: definition)
        let aggregator = GridAggregator(database: database)

        var counted = 0
        try await database.forEachPage(
            matching: CKQuery(
                recordType: "Entity",
                filters: [
                    CKQuery.Filter(field: "entity", op: .equals, value: .string(entity))
                ]
            )
        ) { page in
            for chunk in page.chunked(into: batchSize) {
                let decoded = try chunk.map { try decoder.decode($0) }
                try await aggregator.rebalance(removing: [], adding: decoded, using: scoped)
                counted += decoded.count
            }
        }

        return counted
    }
}

extension EntityDefinition {
    fileprivate func rekey(_ decoded: EntityRecord) -> [String: RecordValue] {
        var predecessors: [String: FieldDefinition] = [:]
        for field in fields(at: decoded.schemaVersion) {
            guard case .slot(_, let slot) = field.storage, predecessors[slot] == nil else {
                continue
            }
            predecessors[slot] = field
        }
        var values: [String: RecordValue] = [:]
        for field in fields(at: version) {
            if let value = decoded.values[field.name] {
                values[field.name] = value
            } else if case .slot(_, let slot) = field.storage {
                values[field.name] = predecessors[slot].flatMap { decoded.values[$0.name] }
            }
        }
        return values
    }
}
