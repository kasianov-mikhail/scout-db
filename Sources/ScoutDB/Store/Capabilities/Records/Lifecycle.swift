//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    /// Lifts a tombstone: the record returns to reads with the values the
    /// tombstone kept, and rejoins its aggregate views.
    ///
    /// Restoring a live record is a no-op that returns it unchanged.
    ///
    @discardableResult public func restore(entity: String, uuid: String) async throws -> EntityRecord {
        let definition = try await registry.definition(for: entity)
        guard let stored = try await items(entity: entity, uuids: [uuid]).first else {
            throw SchemaError.notFound(uuid)
        }
        let coder = EntityCoder(keyProvider: keyProvider, zoneID: zoneID)
        let rewrite = try coder.rewrite(stored, using: definition) { record in
            record.deleted = false
        }
        guard rewrite.previous.deleted else { return rewrite.previous }
        try await database.write(record: rewrite.record)
        try await GridAggregator(database: database).record([rewrite.next], using: definition)
        noteChange(entity: entity)
        return rewrite.next
    }

    /// Physically deletes the entity's tombstones last modified before the cutoff.
    ///
    /// Purged deletes disappear from change feeds and can no longer be restored —
    /// run a compact only past every device's sync horizon.
    ///
    @discardableResult public func compact(entity: String, olderThan cutoff: Date) async throws -> Int {
        let query = ckQuery(
            Entity.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "deleted", op: .equals, value: .int(1)),
                ServerFilter(field: "modificationDate", op: .lessThan, value: .date(cutoff)),
            ])
        let victims = try await database.allRecords(matching: query, inZone: zoneID).map(\.recordID)
        for chunk in victims.chunked(into: 400) {
            try await database.modifyRecords(saving: [], deleting: chunk)
        }
        return victims.count
    }

    /// Tombstones every record of the entity, then retires its schema.
    ///
    /// Returns how many records were tombstoned. The tombstones stay behind for
    /// change feeds; republishing the schema brings the entity back, without its
    /// dropped records.
    ///
    @discardableResult public func drop(entity: String) async throws -> Int {
        let removed = try await deleteAll(entity: entity)
        try await registry.retire(entity: entity)
        return removed
    }
}
