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
        var components = [entity, aggregate, group, "\(Self.date.millisecondsSince1970)"]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "grid-" + contentDigest(of: components))
    }

    var isRenamed: Bool {
        shard == nil && components.contains { $0.contains(where: { $0 == "\\" || $0 == "|" }) }
    }

    func blank(named id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["entity"] = entity
        record["view"] = aggregate
        record[CKRecord.groupCell] = group
        record["date"] = Self.date
        return record
    }
}

extension CKQuery {
    /// The cells of one aggregate, narrowed to a single group when one is named.
    ///
    /// The date column needs no filter of its own: every cell carries
    /// ``GridSlot/date``, so matching on it would narrow nothing.
    static func grid(entity: String, aggregate: String, group: String? = nil) -> CKQuery {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(aggregate)),
        ]
        if let group {
            filters.append(ServerFilter(field: CKRecord.groupCell, op: .equals, value: .string(group)))
        }
        return CKQuery(recordType: GridSlot.recordType, filters: filters)
    }
}
