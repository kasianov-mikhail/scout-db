//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorFetch {
    let database: any CloudDatabase
    let entity: String
    let aggregate: AggregateDefinition

    func rows(groups: [String]?, range: Range<Date>?) async throws -> [VectorRow] {
        let index = VectorIndexReader(database: database, entity: entity, aggregate: aggregate)

        let head = try await index.head
        let weeks = head.weeks(range: range)
        let plan = ShardPlan(aggregate: aggregate, head: head)

        let keys =
            if let groups {
                weeks.flatMap(groups.keys)
            } else {
                try await index.keys(weeks: weeks)
            }

        var named: [CKRecord.ID: VectorKey] = [:]

        for key in keys {
            for shard in plan.shards(week: key.week) {
                let slot = VectorSlot(key: key, entity: entity, aggregate: aggregate, shard: shard)
                named[slot.recordID] = key
            }
        }

        return try await database.fetchRecords(ids: Array(named.keys), batchSize: maxBatchSize).compactMap { record in
            guard let key = named[record.recordID] else {
                return nil
            }
            return VectorRow(group: key.group, week: key.week, record: record)
        }
    }
}

extension VectorSlot {
    fileprivate init(key: VectorKey, entity: String, aggregate: AggregateDefinition, shard: Int?) {
        self.init(
            entity: entity,
            aggregate: aggregate.name,
            group: key.group,
            shard: shard,
            part: key.group.bucket(count: aggregate.partCount),
            week: key.week
        )
    }
}
