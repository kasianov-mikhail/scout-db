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
            Item.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "schema_version", op: .lessThan, value: .int(Int64(definition.version))),
            ])
        let outdated = try await database.allRecords(matching: query)

        // Rewriting reuses the record IDs, so backends upsert in place. Slots freed by the
        // new version keep their old values on the server — correctness relies on the
        // registry invariant that a slot is never reassigned while old records exist.
        // Interrupted runs are safe to repeat: migrated records leave the query above.
        let coder = EntityCoder(keyProvider: keyProvider)
        var migrated: [CKRecord] = []
        for record in outdated {
            let decoded = try coder.decode(record, using: definition)
            guard !decoded.deleted else { continue }
            var entityRecord = EntityRecord(entity: entity, uuid: decoded.uuid, schemaVersion: definition.version, values: rekey(decoded, using: definition))
            try transform(&entityRecord)
            migrated.append(try coder.encode(entityRecord, using: definition))
        }

        try await database.write(records: migrated)
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
