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

    /// Reads the vectors of the aggregate, naming each by the group it counts.
    ///
    /// `groups` names the groups to read when the caller knows them — a filter
    /// narrowed to a value, or the buckets of a histogram — and the index is
    /// only consulted for the weeks. Without them every group the index has
    /// seen is read.
    ///
    func rows(groups: [String]? = nil) async throws -> [Row] {
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

        let ids = named.keys.sorted { $0.recordName < $1.recordName }

        return try await database.fetchRecords(ids: ids, batchSize: maxBatchSize)
            .compactMap { record in
                named[record.recordID].map { (group: $0, record: record) }
            }
    }

    /// The record IDs the aggregate holds, whatever they count.
    func recordIDs() async throws -> [CKRecord.ID] {
        try await rows().map(\.record.recordID)
    }

    /// The index records naming those vectors, which a rebuild drops with them.
    func indexIDs() async throws -> [CKRecord.ID] {
        let head = VectorIndex(entity: entity, aggregate: aggregate.name, week: nil)
        let weeks = try await weeks().map {
            VectorIndex(entity: entity, aggregate: aggregate.name, week: $0)
        }
        return ([head] + weeks).map(\.recordID)
    }

    private var shards: [Int?] {
        guard let count = aggregate.shards else {
            return [nil]
        }
        return (0..<count).map { $0 }
    }

    private func weeks() async throws -> [Date] {
        let head = VectorIndex(entity: entity, aggregate: aggregate.name, week: nil)

        guard let record = try await database.fetchRecord(id: head.recordID) else {
            return []
        }
        return try VectorIndex.page(of: record).weeks.map(Date.init(millisecondsSince1970:))
    }

    private func groups(in weeks: [Date]) async throws -> [(group: String, week: Date)] {
        let pages = weeks.map { VectorIndex(entity: entity, aggregate: aggregate.name, week: $0) }
        let dated = Dictionary(uniqueKeysWithValues: zip(pages.map(\.recordID), weeks))

        let ids = pages.map(\.recordID).sorted { $0.recordName < $1.recordName }
        var keys: [(group: String, week: Date)] = []

        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            guard let week = dated[record.recordID] else {
                continue
            }
            for group in try VectorIndex.page(of: record).groups {
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
