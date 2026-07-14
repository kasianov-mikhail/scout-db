//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    public static let revisionEntity = "_rev"

    /// The append-only revision log behind audited entities; publish it once,
    /// like the transaction envelope.
    public static var revisionDefinition: EntityDefinition {
        EntityDefinition(
            entity: revisionEntity, version: 1,
            fields: [
                FieldDefinition(name: "entity", type: .string, storage: .slot(.string, "s_00"), required: true),
                FieldDefinition(name: "record_uuid", type: .string, storage: .slot(.string, "s_01"), required: true),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "snapshot", type: .bytes, storage: .payload, required: true),
            ], envelopeDate: "date")
    }

    /// The audited record's previous states, oldest first — each one the record
    /// as it stood right before an update or delete overwrote it.
    public func history(entity: String, uuid: String) async throws -> [EntityRecord] {
        let filters = [
            Filter(field: "entity", op: .equals, value: .string(entity)),
            Filter(field: "record_uuid", op: .equals, value: .string(uuid)),
        ]
        let revisions = try await read(entity: Self.revisionEntity, filters: filters, sort: [Sort(field: "date")])
        return revisions.compactMap { revision in
            guard case .bytes(let data)? = revision.values["snapshot"] else { return nil }
            return try? JSONDecoder().decode(EntityRecord.self, from: data)
        }
    }

    // Appends one revision per overwritten record. A mutation of an audited
    // entity calls this after its write lands, so the log can lag by one crash
    // but never invents a revision.
    func recordRevisions(_ previous: [EntityRecord], using definition: EntityDefinition) async throws {
        guard definition.audited == true, previous.count > 0 else { return }
        let encoder = JSONEncoder()
        let writes = try previous.map { record in
            EntityWrite(values: [
                "entity": .string(record.entity),
                "record_uuid": .string(record.uuid),
                "date": .date(Date()),
                "snapshot": .bytes(try encoder.encode(record)),
            ])
        }
        try await write(writes, entity: Self.revisionEntity)
    }
}
