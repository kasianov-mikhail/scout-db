//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorReader {
    let database: any CloudDatabase
    let entity: String
    let aggregate: AggregateDefinition

    typealias Row = (group: String, record: CKRecord)

    func rows(groups: [String]?) async throws -> [Row] {
        let head = try await head()
        let weeks = head.weeks.map(Date.init(millisecondsSince1970:))

        let plan = ShardPlan(floor: aggregate.shards, grown: head.shards)

        let keys: [(group: String, week: Date)] =
            if let groups {
                weeks.flatMap { week in groups.map { (group: $0, week: week) } }
            } else {
                try await self.groups(in: weeks)
            }

        var named: [CKRecord.ID: String] = [:]

        for (group, week) in keys {
            let shards =
                plan.count(for: week).map {
                    (0..<$0).map(Optional.init)
                } ?? [nil]

            for shard in shards {
                let slot = VectorSlot(
                    entity: entity,
                    aggregate: aggregate.name,
                    group: group,
                    shard: shard,
                    week: week
                )
                named[slot.recordID] = group
            }
        }

        let ids = named.keys.sorted {
            $0.recordName < $1.recordName
        }

        return try await database.fetchRecords(
            ids: ids,
            batchSize: maxBatchSize
        )
        .compactMap { record in
            named[record.recordID].map { (group: $0, record: record) }
        }
    }

    private func head() async throws -> IndexPage {
        let head = VectorIndex(
            entity: entity,
            aggregate: aggregate.name,
            week: nil
        )

        guard let record = try await database.fetchRecord(id: head.recordID) else {
            return IndexPage(
                weeks: [],
                groups: []
            )
        }

        return try record.indexPage(named: head.recordID)
    }

    private func groups(in weeks: [Date]) async throws -> [(group: String, week: Date)] {
        let pages = weeks.map {
            VectorIndex(
                entity: entity,
                aggregate: aggregate.name,
                week: $0
            )
        }

        let dated = Dictionary(
            uniqueKeysWithValues: zip(pages.map(\.recordID), weeks)
        )

        let ids = pages.map(\.recordID).sorted {
            $0.recordName < $1.recordName
        }

        var keys: [(group: String, week: Date)] = []
        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            guard let week = dated[record.recordID] else {
                continue
            }
            for group in try record.indexPage(named: record.recordID).groups {
                keys.append((group: group, week: week))
            }
        }

        return keys
    }
}
