//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorReader<Holder: Vector> {
    let database: any CloudDatabase
    let entity: String
    let aggregate: AggregateDefinition

    typealias Row = (group: String, record: CKRecord)

    func rows(groups: [String]?) async throws -> [Row] {
        let weeks = try await weeks()

        guard weeks.count > 0 else {
            return []
        }

        let keys: [(group: String, week: Date)] =
            if let groups {
                weeks.flatMap { week in groups.map { (group: $0, week: week) } }
            } else {
                try await self.groups(in: weeks)
            }

        var named: [CKRecord.ID: String] = [:]

        for (group, week) in keys {
            for shard in shards {
                let slot = VectorSlot<Holder>(
                    entity: entity,
                    aggregate: aggregate.name,
                    group: group,
                    shard: shard,
                    week: week
                )
                named[slot.recordID] = group
            }
        }

        let ids = named.keys.sorted { $0.recordName < $1.recordName }

        return try await database.fetchRecords(ids: ids, batchSize: maxBatchSize)
            .compactMap { record in
                named[record.recordID].map { (group: $0, record: record) }
            }
    }

    func indexIDs() async throws -> [CKRecord.ID] {
        let head = VectorIndex(slug: Holder.slug, entity: entity, aggregate: aggregate.name, week: nil)
        let weeks = try await weeks().map {
            VectorIndex(slug: Holder.slug, entity: entity, aggregate: aggregate.name, week: $0)
        }
        return ([head] + weeks).map(\.recordID)
    }

    private var shards: [Int?] {
        guard let count = aggregate.shards else {
            return [nil]
        }
        return (0..<count).map(Optional.init)
    }

    private func weeks() async throws -> [Date] {
        let head = VectorIndex(slug: Holder.slug, entity: entity, aggregate: aggregate.name, week: nil)

        guard let record = try await database.fetchRecord(id: head.recordID) else {
            return []
        }
        return try record.indexPage(named: head.recordID).weeks.map(Date.init(millisecondsSince1970:))
    }

    private func groups(in weeks: [Date]) async throws -> [(group: String, week: Date)] {
        let pages = weeks.map { VectorIndex(slug: Holder.slug, entity: entity, aggregate: aggregate.name, week: $0) }
        let dated = Dictionary(uniqueKeysWithValues: zip(pages.map(\.recordID), weeks))

        let ids = pages.map(\.recordID).sorted { $0.recordName < $1.recordName }
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

extension VectorReader {
    init(database: any CloudDatabase, definition: EntityDefinition, aggregate: AggregateDefinition) {
        self.init(database: database, entity: definition.entity, aggregate: aggregate)
    }
}
