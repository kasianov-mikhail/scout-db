//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorIndex: Hashable {
    static let namespace = "__index"

    let entity: String
    let aggregate: String
    let week: Date?

    var recordID: CKRecord.ID {
        var components = [entity, aggregate]
        if let week {
            components.append(String(week.millisecondsSince1970))
        }
        return CKRecord.ID(recordName: "index-" + contentDigest(of: components))
    }

    func blank() -> CKRecord {
        let record = CKRecord(recordType: SchemaDescriptorEntry.recordType, recordID: recordID)
        record[Envelope.entity] = Self.namespace
        record[Envelope.version] = Int64(1)
        return record
    }
}

extension VectorIndex {
    struct Page: Codable, Equatable {
        let weeks: [Int64]
        let groups: [String]

        init(weeks: [Int64] = [], groups: [String] = []) {
            self.weeks = weeks
            self.groups = groups
        }
    }

    static let pageKey = "b_00"
}

extension CKRecord {
    var indexPage: VectorIndex.Page? {
        get {
            guard let data = self[VectorIndex.pageKey] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(VectorIndex.Page.self, from: data)
        }
        set {
            let encoded: Data? = newValue.flatMap { try? JSONEncoder().encode($0) }
            self[VectorIndex.pageKey] = encoded
        }
    }

    func indexPage(named id: CKRecord.ID) throws -> VectorIndex.Page {
        guard let page = indexPage else {
            throw SchemaError.malformedRecord(id.recordName)
        }
        return page
    }
}

extension VectorSlot {
    var index: (head: VectorIndex, week: VectorIndex) {
        (
            VectorIndex(entity: entity, aggregate: aggregate, week: nil),
            VectorIndex(entity: entity, aggregate: aggregate, week: week)
        )
    }
}
