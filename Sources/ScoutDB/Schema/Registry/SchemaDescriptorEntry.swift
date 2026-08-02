//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct SchemaDescriptorEntry {
    static let recordType = "SchemaDescriptor"

    let entity: String
    let version: Int
    let definition: Data

    init(record: CKRecord) throws {
        guard let entity = record["entity"] as? String, let version = record["entity_version"] as? Int64 else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }
        guard let definition = record["definition"] as? Data else {
            throw SchemaError.malformedRecord(record.recordID.recordName)
        }
        self.entity = entity
        self.version = Int(version)
        self.definition = definition
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

extension CKQuery {
    convenience init(activeSchemasOf entity: String) {
        self.init(
            recordType: SchemaDescriptorEntry.recordType,
            filters: [
                CKQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                CKQuery.Filter(field: "status", op: .equals, value: .string("active")),
            ]
        )
    }
}
