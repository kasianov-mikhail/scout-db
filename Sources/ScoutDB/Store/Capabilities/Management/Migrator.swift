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

    /// Rebuilds one view's grid from the entity's live records.
    ///
    /// The pass for a view declared after data already exists — its grid only
    /// counts contributions from the moment of declaration, and this recounts
    /// the past. It drops the view's existing grid records first, so repeating
    /// an interrupted run is safe and the same call repairs a drifted grid.
    /// Quiesce writers for the duration: a write landing mid-rebuild can count
    /// twice or not at all. Returns how many records contributed.
    ///
    /// Wins a claim for every enforced-key value the entity's live records hold.
    ///
    /// Run once after declaring `enforcedKey(on:)` over existing data: claims
    /// exist only for records written after the declaration, so until this pass
    /// completes an old value can be re-taken. A duplicate already present in
    /// the data surfaces as `duplicateKey` — resolve it and run again; repeating
    /// the run is safe. Returns how many records were processed.
    ///
    @discardableResult public func backfillClaims(entity: String, batchSize: Int = 400) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard definition.enforcedKeys?.isEmpty == false else { return 0 }
        let store = EntityStore(database: database, registry: registry, keyProvider: keyProvider)
        let records = try await store.read(entity: entity)
        for chunk in records.chunked(into: batchSize) {
            try await store.claimUniqueKeys(of: chunk, using: definition)
        }
        return records.count
    }

    @discardableResult public func backfill(view viewName: String, entity: String, batchSize: Int = 400) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }

        let grid = try await database.allRecords(
            matching: ckQuery(
                Aggregate.recordType,
                filters: [
                    ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                    ServerFilter(field: "view", op: .equals, value: .string(viewName)),
                ]))
        for chunk in grid.map(\.recordID).chunked(into: batchSize) {
            try await database.modifyRecords(saving: [], deleting: chunk)
        }

        var scoped = definition
        scoped.views = [view]
        let records = try await database.allRecords(
            matching: ckQuery(
                Entity.recordType,
                filters: [
                    ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                    ServerFilter(field: "deleted", op: .equals, value: .int(0)),
                ]))
        let coder = EntityCoder(keyProvider: keyProvider)
        let aggregator = GridAggregator(database: database)
        var counted = 0
        for chunk in records.chunked(into: batchSize) {
            let decoded = try chunk.map { try coder.decode($0, using: definition) }
            try await aggregator.record(decoded, using: scoped)
            counted += decoded.count
        }
        return counted
    }

    /// Re-encrypts every live record of an entity under a new key and republishes
    /// the definition with the new keyID.
    ///
    /// The migrator's provider must serve both keys. An interrupted run is safe to
    /// repeat: a record already sealed under the new key fails to open with the old
    /// one and is decoded — and re-sealed — with the new key instead. Quiesce other
    /// readers for the duration; until the republished definition reaches them,
    /// rotated records fail to decrypt with the old key.
    ///
    @discardableResult public func rotateKey(entity: String, to newKeyID: String) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        guard let oldKeyID = definition.keyID, oldKeyID != newKeyID else {
            throw SchemaError.missingKey(newKeyID)
        }
        var rotated = definition
        rotated.keyID = newKeyID

        let query = ckQuery(
            Entity.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "deleted", op: .equals, value: .int(0)),
            ])
        let coder = EntityCoder(keyProvider: keyProvider)
        let rewritten = try await database.allRecords(matching: query).map { record -> CKRecord in
            let decoded: EntityRecord
            do {
                decoded = try coder.decode(record, using: definition)
            } catch {
                decoded = try coder.decode(record, using: rotated)
            }
            var next = decoded
            next.values = try coder.resolve(next.values, at: next.schemaVersion, using: rotated)
            return try coder.encode(next, using: rotated, into: record)
        }
        try await database.write(records: rewritten)
        try await registry.publish(rotated)
        return rewritten.count
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
