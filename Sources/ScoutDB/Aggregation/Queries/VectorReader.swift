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
    let definition: EntityDefinition
    let aggregate: AggregateDefinition

    typealias Row = (group: String, week: Date, record: CKRecord)

    private var entity: String {
        definition.entity
    }

    func rows(groups: [String]?, in range: Range<Date>? = nil) async throws -> [Row] {
        guard let since = aggregate.since, let date = aggregate.date else {
            return try await vectorRows(groups: groups, in: range)
        }
        guard (range?.lowerBound ?? .distantPast) < since else {
            return try await vectorRows(groups: groups, in: range)
        }

        async let counted = vectorRows(groups: groups, in: range)
        async let missing = recordRows(groups: groups, date: date, since: since, range: range)

        return try await counted.compactMap { Self.row($0, from: since) } + missing
    }

    private func vectorRows(groups: [String]?, in range: Range<Date>?) async throws -> [Row] {
        let head = try await head()
        let weeks = head.weeks.map(Date.init(millisecondsSince1970:)).filter { week in
            range.map { week.covers($0) } ?? true
        }

        let plan = ShardPlan(floor: aggregate.shards, grown: head.shards)

        let keys: [(group: String, week: Date)] =
            if let groups {
                weeks.flatMap { week in groups.map { (group: $0, week: week) } }
            } else {
                try await self.groups(in: weeks)
            }

        var named: [CKRecord.ID: (group: String, week: Date)] = [:]

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
                named[slot.recordID] = (group: group, week: week)
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
            named[record.recordID].map { (group: $0.group, week: $0.week, record: record) }
        }
    }

    private func recordRows(groups: [String]?, date: String, since: Date, range: Range<Date>?) async throws -> [Row] {
        var filters = [ClientFilter(field: date, op: .lessThan, value: .date(min(range?.upperBound ?? since, since)))]
        if let lower = range?.lowerBound {
            filters.append(ClientFilter(field: date, op: .greaterThanOrEquals, value: .date(lower)))
        }

        let fields = [date, aggregate.groupBy, aggregate.measure?.field, aggregate.measure?.histogram?.field]

        let records = try await ReadOperation(
            database: database,
            definition: definition,
            branches: [filters],
            sort: [],
            fields: fields.compactMap(\.self)
        )
        .records()

        return [aggregate].deltas(removing: [], adding: records, at: since, spread: [:])
            .filter { slot, _ in groups?.contains(slot.group) ?? true }
            .map { slot, delta in
                let record = CKRecord(recordType: VectorSlot.recordType, recordID: slot.recordID)
                delta.apply(to: record)
                return (group: slot.group, week: slot.week, record: record)
            }
    }

    private static func row(_ row: Row, from since: Date) -> Row? {
        guard row.week < since else {
            return row
        }
        guard row.week.hour(Date.hoursPerWeek) > since else {
            return nil
        }

        let record = row.record.duplicate()
        for hour in 0..<Date.hoursPerWeek where row.week.hour(hour) < since {
            record[VectorSlot.cellKeys[hour]] = nil
        }
        return (group: row.group, week: row.week, record: record)
    }

    private func head() async throws -> IndexPage {
        let head = VectorIndex(
            entity: entity,
            aggregate: aggregate.name,
            week: nil
        )

        guard let record = try await database.fetchRecord(id: head.recordID) else {
            // A head no record answers is fetched again on every read of the
            // aggregate, and CloudKit counts each miss against the container
            // until it slows the whole client down. Writing the empty page
            // costs one miss instead; a reader that may not write reads on.
            try? await VectorIndexWriter(database: database).seed(head)

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
