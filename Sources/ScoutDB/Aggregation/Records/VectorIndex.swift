//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// The names of the vectors an aggregate keeps, which a vector no longer
/// carries itself.
///
/// A vector is reached by the digest of its key, so nothing has to be filtered
/// server-side — but a fold over every group has to know which groups exist.
/// That list lives here: one record per aggregate holding the weeks it spans,
/// and one record per week holding the groups seen in it.
///
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
        var weeks: [Int64] = []
        var groups: [String] = []

        var isEmpty: Bool {
            weeks.isEmpty && groups.isEmpty
        }
    }

    static let pageKey = "b_00"

    static func page(of record: CKRecord) throws -> Page {
        guard let data = record[pageKey] as? Data else {
            return Page()
        }
        return try JSONDecoder().decode(Page.self, from: data)
    }

    static func store(_ page: Page, in record: CKRecord) throws {
        record[pageKey] = try JSONEncoder().encode(page)
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
