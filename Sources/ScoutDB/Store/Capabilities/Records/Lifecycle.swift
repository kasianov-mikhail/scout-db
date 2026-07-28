//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    @discardableResult public func restore(entity: String, uuid: String) async throws -> EntityRecord {
        let definition = try await registry.definition(for: entity)
        guard let stored = try await items(entity: entity, uuids: [uuid]).first else {
            throw SchemaError.notFound(uuid)
        }
        let coder = EntityCoder(keyProvider: keyProvider)
        let rewrite = try coder.rewrite(stored, using: definition) { record in
            record.deleted = false
        }
        guard rewrite.previous.deleted else { return rewrite.previous }
        try await claimUniqueKeys(of: [rewrite.next], using: definition)
        try await database.write(record: rewrite.record)
        try await aggregator.record([rewrite.next], using: definition)
        noteChange(entity: entity, changed: [rewrite.next])
        return rewrite.next
    }

    @discardableResult public func compact(entity: String, olderThan cutoff: Date) async throws -> Int {
        let query = ckQuery(
            Entity.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "deleted", op: .equals, value: .int(1)),
                ServerFilter(field: "modificationDate", op: .lessThan, value: .date(cutoff)),
            ])
        let victims = try await database.allRecords(matching: query).map(\.recordID)
        try await database.delete(records: victims)
        return victims.count
    }

    func purge(entity: String, filters: [Filter]) async throws -> Int {
        let victims = try await read(entity: entity, filters: filters, fields: [])
        let ids = victims.map { CKRecord.ID(recordName: $0.uuid) }
        try await database.delete(records: ids)
        return ids.count
    }

    @discardableResult public func drop(entity: String) async throws -> Int {
        let removed = try await deleteAll(entity: entity)
        try await registry.retire(entity: entity)
        return removed
    }
}
