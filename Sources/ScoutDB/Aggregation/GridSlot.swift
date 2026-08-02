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
    let aggregate: String
    let group: String
    let shard: Int?

    private var components: [String] {
        var components = [entity, aggregate, group]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "grid-" + contentDigest(of: components))
    }

    func blank(named id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["entity"] = entity
        record["aggregate"] = aggregate
        record[CKRecord.groupCell] = group
        record["date"] = Self.date
        return record
    }
}

extension CKQuery {
    convenience init(gridOf entity: String, aggregate: String, group: String? = nil) {
        var filters = [
            CKQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
            CKQuery.Filter(field: "aggregate", op: .equals, value: .string(aggregate)),
        ]
        if let group {
            filters.append(CKQuery.Filter(field: CKRecord.groupCell, op: .equals, value: .string(group)))
        }
        self.init(recordType: GridSlot.recordType, filters: filters)
    }
}
