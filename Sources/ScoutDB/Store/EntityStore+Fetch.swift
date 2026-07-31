//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    public func fetch(entity: String, uuids: [String]) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        let records = try await items(entity: entity, uuids: uuids)
        return try decode(records, using: definition).sorted { $0.uuid < $1.uuid }
    }

    /// Fetches a single record by its identifier, resolving the entity from the record itself.
    ///
    /// The record carries the uuid as its name, so this reaches it by ID and
    /// reads a just-written record — a query would go through the index, which
    /// lags a write.
    ///
    public func fetch(uuid: String) async throws -> EntityRecord? {
        let id = CKRecord.ID(recordName: uuid)
        guard let record = try await database.fetchRecord(id: id) else {
            return nil
        }
        guard let entity = record["entity"] as? String else {
            return nil
        }
        let definition = try await registry.definition(for: entity)
        return try decode([record], using: definition).first
    }

    func items(entity: String, uuids: [String]) async throws -> [CKRecord] {
        let ids = uuids.map { CKRecord.ID(recordName: $0) }
        return try await database.fetchRecords(ids: ids, batchSize: 100).filter { $0["entity"] as? String == entity }
    }
}
