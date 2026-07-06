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
                entityRecord = EntityRecord(
                    entity: entity, uuid: entityRecord.uuid, schemaVersion: definition.version, values: rekey(entityRecord, using: definition))
                try transform(&entityRecord)
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
