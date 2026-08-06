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

    let entity: String
    let version: Int
    let definition: Data

    init(record: CKRecord) throws {
        guard let entity = record[Slot.entity] as? String, let version = record["schema_version"] as? Int64 else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }
        guard let definition = record[Slot.definition] as? Data else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }
        self.entity = entity
        self.version = Int(version)
        self.definition = definition
    }

    fileprivate enum Slot {
        static let entity = "s_00"
        static let status = "s_01"
        static let definition = "b_00"
    }
}

extension SchemaDescriptorEntry {
    static func query(for entity: String) -> CKQuery {
        CKQuery(
            recordType: recordType,
            filters: [
                CKQuery.Filter(field: "entity", op: .equals, value: .string(namespace)),
                CKQuery.Filter(field: Slot.entity, op: .equals, value: .string(entity)),
                CKQuery.Filter(field: Slot.status, op: .equals, value: .string("active")),
            ]
        )
    }

    static func record(for definition: EntityDefinition) throws -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: "\(definition.entity)@\(definition.version)")
        )
        record["entity"] = namespace
        record["schema_version"] = Int64(definition.version)
        record[Slot.entity] = definition.entity
        record[Slot.status] = "active"
        record[Slot.definition] = try JSONEncoder().encode(definition)

        return record
    }
}

extension SchemaDescriptorEntry: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.version < rhs.version
    }
}

extension [SchemaDescriptorEntry] {
    var latest: EntityDefinition? {
        get throws {
            guard let entry = self.max() else {
                return nil
            }
            let definition = try JSONDecoder().decode(EntityDefinition.self, from: entry.definition)
            try definition.validate()
            return definition
        }
    }
}
