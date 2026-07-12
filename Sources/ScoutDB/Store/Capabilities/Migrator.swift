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
    var keyProvider: (any EncryptionKeyProvider)?

    /// Creates a migrator backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil) {
        self.database = database
        self.registry = registry
        self.keyProvider = keyProvider
    }

    @discardableResult public func backfill(entity: String, transform: (inout EntityRecord) throws -> Void = { _ in }) async throws -> Int {
        try await backfill(entity: entity) { record, _ in try transform(&record) }
    }

    /// Renames a field's data: rewrites every outdated record, carrying the value
    /// stored under `from` at the record's version into `to` at the current one.
    ///
    /// Needed when the rename allocated a fresh slot for the new name — a rename
    /// that reuses the old field's slot across disjoint version ranges migrates
    /// through a plain `backfill` already. Repeating the run is safe: migrated
    /// records leave the outdated set.
    ///
    @discardableResult public func rename(entity: String, from: String, to: String) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard definition.field(named: to, at: definition.version) != nil else {
            throw SchemaError.unknownField(to)
        }
        return try await backfill(entity: entity) { record, previous in
            record.values[to] = record.values[to] ?? previous.values[from]
        }
    }

    // The full rewrite loop; `transform` also receives the record as decoded at its
    // stored version, before rekeying — the only place a renamed-away value survives.
    @discardableResult public func backfill(entity: String, transform: (inout EntityRecord, _ previous: EntityRecord) throws -> Void) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let query = ckQuery(
            Entity.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "schema_version", op: .lessThan, value: .int(Int64(definition.version))),
                ServerFilter(field: "deleted", op: .equals, value: .int(0)),
            ])
        let outdated = try await database.allRecords(matching: query)

        // Rewriting goes back into the stored records, so backends upsert in place. Slots
        // freed by the new version keep their old values on the server — correctness relies
        // on the registry invariant that a slot is never reassigned while old records exist.
        // Interrupted runs are safe to repeat: migrated records leave the query above.
        let coder = EntityCoder(keyProvider: keyProvider)
        let migrated = try outdated.map { record in
            try coder.rewrite(record, using: definition) { entityRecord in
                let previous = entityRecord
                entityRecord = EntityRecord(
                    entity: entity, uuid: previous.uuid, schemaVersion: definition.version, values: rekey(previous, using: definition))
                try transform(&entityRecord, previous)
            }
        }

        try await database.write(records: migrated.map(\.record))
        return migrated.count
    }

    private func rekey(_ decoded: EntityRecord, using definition: EntityDefinition) -> [String: RecordValue] {
        let oldFields = definition.fields(at: decoded.schemaVersion)
        var values: [String: RecordValue] = [:]
        for field in definition.fields(at: definition.version) {
            if let value = decoded.values[field.name] {
                values[field.name] = value
            } else if case .slot(let pool, let slot) = field.storage {
                let predecessor = oldFields.first { .slot(pool, slot) == $0.storage }
                values[field.name] = predecessor.flatMap { decoded.values[$0.name] }
            }
        }
        return values
    }
}
