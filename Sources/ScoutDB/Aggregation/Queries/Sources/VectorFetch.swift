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
        let plan = ShardPlan(floor: aggregate.shards, grown: head.shards)

        let keys =
            if let groups {
                weeks.flatMap(groups.keys)
            } else {
                try await index.keys(weeks: weeks)
            }

        var named: [CKRecord.ID: VectorKey] = [:]

        for key in keys {
            for shard in plan.shards(for: key.week) {
                let slot = VectorSlot(
                    key: key,
                    entity: entity,
                    aggregate: aggregate.name,
                    shard: shard
                )
                named[slot.recordID] = key
            }
        }

        let ids = named.keys.sorted { $0.recordName < $1.recordName }

        return try await database.fetchRecords(ids: ids, batchSize: maxBatchSize).compactMap { record in
            guard let key = named[record.recordID] else {
                return nil
            }
            return VectorRow(group: key.group, week: key.week, record: record)
        }
    }
}

extension VectorSlot {
    fileprivate init(key: VectorKey, entity: String, aggregate: String, shard: Int?) {
        self.init(entity: entity, aggregate: aggregate, group: key.group, shard: shard, week: key.week)
    }
}
