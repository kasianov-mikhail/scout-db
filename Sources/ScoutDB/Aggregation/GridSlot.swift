//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridSlot: Hashable {
    static let recordType = "Aggregate"

    /// The date every grid record carries.
    ///
    /// The grid keeps one running cell per group rather than a row of them over
    /// time, so the column the record type declares holds the same value
    /// throughout.
    static let date = Date(timeIntervalSince1970: 0)

    let entity: String
    let view: String
    let group: String
    let shard: Int?

    private var components: [String] {
        var components = [entity, view, group, "\(Self.date.millisecondsSince1970)"]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "grid-" + contentDigest(of: components))
    }

    var isRenamed: Bool {
        shard == nil && escapesSeparators(components)
    }

    func blank(named id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["entity"] = entity
        record["view"] = view
        record["group_key"] = group
        record["date"] = Self.date
        return record
    }
}
