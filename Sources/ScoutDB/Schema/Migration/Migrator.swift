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

    @discardableResult public func backfill(entity: String, transform: (inout EntityRecord) throws -> Void = { _ in }) async throws -> Int {
        try await backfill(entity: entity) { record, _ in try transform(&record) }
    }

    @discardableResult public func rename(entity: String, from: String, to: String) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard definition.field(named: to, at: definition.version) != nil else {
            throw SchemaError.unknownField(to)
        }
        return try await backfill(entity: entity) { record, previous in
            record.values[to] = record.values[to] ?? previous.values[from]
        }
    }

    @discardableResult public func backfill(entity: String, transform: (inout EntityRecord, _ previous: EntityRecord) throws -> Void) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let query = CKQuery(
            recordType: "Entity",
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "schema_version", op: .lessThan, value: .int(Int64(definition.version))),
            ])
        let coder = EntityCoder()
        var migrated = 0
        try await database.forEachPage(matching: query) { page in
            let rewritten = try page.map { record in
                try coder.rewrite(record, using: definition) { entityRecord in
                    let previous = entityRecord
                    entityRecord = EntityRecord(
                        entity: entity, uuid: previous.uuid, schemaVersion: definition.version, values: rekey(previous, using: definition))
                    try transform(&entityRecord, previous)
                }
            }
            guard rewritten.count > 0 else {
                return
            }
            try await database.write(records: rewritten.map(\.record))
            migrated += rewritten.count
        }
        return migrated
    }

    @discardableResult public func backfill(view viewName: String, entity: String, batchSize: Int = 400) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }

        try await database.forEachPage(
            matching: CKQuery(
                recordType: GridSlot.recordType,
                filters: [
                    ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                    ServerFilter(field: "view", op: .equals, value: .string(viewName)),
                ])
        ) { page in
            for chunk in page.map(\.recordID).chunked(into: batchSize) {
                try await database.modifyRecords(saving: [], deleting: chunk)
            }
        }

        var scoped = definition
        scoped.views = [view]
        let coder = EntityCoder()
        let aggregator = GridAggregator(database: database)
        var counted = 0
        try await database.forEachPage(
            matching: CKQuery(
                recordType: "Entity",
                filters: [
                    ServerFilter(field: "entity", op: .equals, value: .string(entity))
                ])
        ) { page in
            for chunk in page.chunked(into: batchSize) {
                let decoded = try chunk.map { try coder.decode($0, using: definition) }
                try await aggregator.record(decoded, using: scoped)
                counted += decoded.count
            }
        }
        return counted
    }

    private func rekey(_ decoded: EntityRecord, using definition: EntityDefinition) -> [String: RecordValue] {
        var predecessors: [String: FieldDefinition] = [:]
        for field in definition.fields(at: decoded.schemaVersion) {
            guard case .slot(_, let slot) = field.storage, predecessors[slot] == nil else {
                continue
            }
            predecessors[slot] = field
        }
        var values: [String: RecordValue] = [:]
        for field in definition.fields(at: definition.version) {
            if let value = decoded.values[field.name] {
                values[field.name] = value
            } else if case .slot(_, let slot) = field.storage {
                values[field.name] = predecessors[slot].flatMap { decoded.values[$0.name] }
            }
        }
        return values
    }
}
