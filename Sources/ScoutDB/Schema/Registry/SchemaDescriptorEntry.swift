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
    static let namespace = "__schema"

    let definition: EntityDefinition

    fileprivate enum Slot {
        static let definition = "b_00"
    }
}

extension SchemaDescriptorEntry {
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

    static func recordID(entity: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "schema-" + contentDigest(components: [entity]))
    }

    var record: CKRecord {
        get throws {
            let id = Self.recordID(entity: definition.entity)
            let record = CKRecord(recordType: Self.recordType, recordID: id)

            record[Envelope.entity] = Self.namespace
            record[Envelope.uuid] = id.recordName
            record[Envelope.version] = Int64(definition.version)
            record[Slot.definition] = try JSONEncoder().encode(definition)

            return record
        }
    }
}
