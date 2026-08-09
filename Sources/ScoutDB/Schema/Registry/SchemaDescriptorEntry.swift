//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct SchemaDescriptorEntry {
    static let recordType = "Entity"

    /// The entity the registry files its own records under, held back from
    /// the names a caller may declare so that no scan over an entity's
    /// records can reach them.
    static let namespace = "__schema"

    let definition: EntityDefinition

    init(record: CKRecord) throws {
        guard record[Envelope.entity] as? String == Self.namespace else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }
        guard let blob = record[Slot.definition] as? Data else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }

        definition = try JSONDecoder().decode(EntityDefinition.self, from: blob)
        try definition.validate()
    }

    fileprivate enum Slot {
        static let definition = "b_00"
    }
}

extension SchemaDescriptorEntry {
    /// The one record an entity's definition is kept under.
    ///
    /// The name is a digest of the entity's, so a definition is reached by
    /// identifier rather than through a query. A query goes through the index,
    /// which lags a write, and the first read after a `create()` is exactly the
    /// one that would race it.
    ///
    /// A digest rather than the entity spelled out because CloudKit names a
    /// record from a narrow alphabet and keeps the leading underscore for
    /// itself, while an entity is any string a caller picks. The entity stays
    /// legible in the definition the record carries, and the namespace stamp is
    /// what a read checks.
    ///
    static func recordID(for entity: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "schema-" + contentDigest(of: [entity]))
    }

    /// The record a publish saves, which overwrites the version before it.
    ///
    /// A version is what the record carries, not part of what it is called, so
    /// publishing upserts one record per entity rather than adding one per
    /// version. Records written under an earlier version stay readable all the
    /// same: the definition carries the version each of its fields opened and
    /// closed at, and a record decodes through the version it names.
    ///
    static func record(for definition: EntityDefinition) throws -> CKRecord {
        let id = recordID(for: definition.entity)
        let record = CKRecord(recordType: recordType, recordID: id)

        record[Envelope.entity] = namespace
        record[Envelope.uuid] = id.recordName
        record[Envelope.version] = Int64(definition.version)
        record[Slot.definition] = try JSONEncoder().encode(definition)

        return record
    }
}
