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
        let decoder = EntityDecoder(definition: definition)
        let ids = uuids.map(CKRecord.ID.init(recordName:))
        let records = try await database.fetchRecords(ids: ids, batchSize: 100)
            .filter { $0[Envelope.entity] as? String == entity }
        return try records.map(decoder.decode).sorted(using: FieldOrder(key: .uuid))
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
        guard let entity = record[Envelope.entity] as? String else {
            return nil
        }
        let definition = try await registry.definition(for: entity)
        return try EntityDecoder(definition: definition).decode(record)
    }
}
