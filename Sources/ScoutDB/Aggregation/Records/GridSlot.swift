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
        record["date"] = Date(timeIntervalSince1970: 0)
        return record
    }
}

extension GridSlot {
    init(for entityRecord: EntityRecord, aggregate: AggregateDefinition) {
        self.init(
            entity: entityRecord.entity,
            aggregate: aggregate.name,
            group: aggregate.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? "",
            shard: aggregate.shards.map { count in
                Int(entityRecord.uuid.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
            }
        )
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
