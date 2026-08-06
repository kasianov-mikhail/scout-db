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
    let week: Date

    private var components: [String] {
        var components = [entity, aggregate, group, String(week.millisecondsSince1970)]
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
        record["group_key"] = group
        record["date"] = week
        return record
    }
}

extension GridSlot {
    init?(for entityRecord: EntityRecord, aggregate: AggregateDefinition, week: Date) {
        let group: String

        if let histogram = aggregate.measure?.histogram {
            guard let value = entityRecord.values[histogram.field]?.scalar else {
                return nil
            }
            group = histogram.groupKey(of: value)
        } else {
            group = aggregate.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
        }

        self.init(
            entity: entityRecord.entity,
            aggregate: aggregate.name,
            group: group,
            shard: aggregate.shards.map { count in
                Int(entityRecord.uuid.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
            },
            week: week
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
            filters.append(CKQuery.Filter(field: "group_key", op: .equals, value: .string(group)))
        }
        self.init(recordType: GridSlot.recordType, filters: filters)
    }
}
