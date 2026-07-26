//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridAggregator {
    let database: any CloudDatabase
    let maxRetry = 3

    func record(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await rebalance(removing: [], adding: batch, using: definition)
    }

    func remove(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await rebalance(removing: batch, adding: [], using: definition)
    }

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord], using definition: EntityDefinition) async throws {
        var merged = deltas(for: old, using: definition, adding: false)
        for (slot, cells) in deltas(for: new, using: definition, adding: true) {
            for (index, delta) in cells {
                merged[slot, default: [:]][index] = merged[slot]?[index].map { Self.merge($0, delta) } ?? delta
            }
        }
        try await apply(
            merged.compactMapValues { cells in
                let live = cells.filter { !$0.value.isNoop }
                return live.isEmpty ? nil : live
            })
    }

    private static func merge(_ lhs: CellDelta, _ rhs: CellDelta) -> CellDelta {
        var merged = lhs
        merged.count += rhs.count
        if let squares = rhs.squares {
            merged.squares = (merged.squares ?? 0) + squares
        }
        if let (kind, total) = rhs.value {
            merged.value = (kind, merged.value.map { kind.combine($0.total, total) } ?? total)
        }
        return merged
    }

    private func deltas(for batch: [EntityRecord], using definition: EntityDefinition, adding: Bool) -> [GridSlot: [Int: CellDelta]] {
        let sign: Int64 = adding ? 1 : -1
        var deltas: [GridSlot: [Int: CellDelta]] = [:]

        for entityRecord in batch where entityRecord.deleted == false {
            var envelope: Date?
            if let dateField = definition.envelopeDate, case .date(let date)? = entityRecord.values[dateField] {
                envelope = date
            }

            for view in definition.views ?? [] {
                let group = view.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
                let shard = view.shards.map { Self.shard(of: entityRecord.uuid, among: $0) }

                if let histogram = view.histogram {
                    guard let date = envelope, let value = entityRecord.values[histogram.field]?.scalar else { continue }
                    let slot = GridSlot(
                        entity: entityRecord.entity, view: view.name, group: group, day: EntityCoder.periodStart(of: .day, for: date), shard: shard)
                    let index = histogram.bounds.firstIndex { value < $0 } ?? histogram.bounds.count
                    deltas[slot, default: [:]][index, default: CellDelta()].count += sign
                    continue
                }

                let bucket = view.bucket ?? .hour
                guard let date = envelope ?? (bucket == .lifetime ? Date(timeIntervalSince1970: 0) : nil) else { continue }
                let (period, index) = Self.bucket(bucket, for: date)
                let slot = GridSlot(entity: entityRecord.entity, view: view.name, group: group, day: period, shard: shard)
                var delta = deltas[slot, default: [:]][index, default: CellDelta()]
                delta.count += sign
                if let (kind, field) = view.metric, let value = entityRecord.values[field]?.scalar {
                    if adding {
                        delta.value = (kind, delta.value.map { kind.combine($0.total, value) } ?? value)
                    } else if kind == .sum {
                        delta.value = (.sum, (delta.value?.total ?? 0) - value)
                    }
                }
                if let scalar = view.stats.flatMap({ entityRecord.values[$0]?.scalar }) {
                    delta.squares = (delta.squares ?? 0) + Double(sign) * scalar * scalar
                }
                deltas[slot, default: [:]][index] = delta
            }
        }
        return deltas
    }

    private func apply(_ deltas: [GridSlot: [Int: CellDelta]]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (slot, cells) in deltas {
                group.addTask { try await apply(cells, to: slot) }
            }
            try await group.waitForAll()
        }
    }

    private struct GridSlot: Hashable {
        let entity: String
        let view: String
        let group: String
        let day: Date
        let shard: Int?
    }

    static func shard(of uuid: String, among count: Int) -> Int {
        Int(uuid.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
    }

    private struct CellDelta {
        var count: Int64 = 0
        var value: (kind: AggregateView.Metric, total: Double)?
        var squares: Double?

        var isNoop: Bool {
            count == 0 && (squares ?? 0) == 0 && (value.map { $0.kind == .sum && $0.total == 0 } ?? true)
        }
    }

    static func bucket(_ bucket: AggregateView.Bucket, for date: Date) -> (period: Date, index: Int) {
        let calendar = EntityCoder.calendar
        switch bucket {
        case .hour:
            return (EntityCoder.periodStart(of: .day, for: date), calendar.component(.hour, from: date))
        case .weekday:
            return (EntityCoder.periodStart(of: .weekOfYear, for: date), calendar.component(.weekday, from: date) - 1)
        case .day:
            return (EntityCoder.periodStart(of: .month, for: date), calendar.component(.day, from: date) - 1)
        case .lifetime:
            return (Date(timeIntervalSince1970: 0), 0)
        }
    }

    private func apply(_ cells: [Int: CellDelta], to slot: GridSlot) async throws {
        var record = try await lookup(entity: slot.entity, view: slot.view, group: slot.group, day: slot.day, shard: slot.shard)

        for _ in 0..<maxRetry {
            for (index, delta) in cells {
                let countCell = Aggregate.countCell(index)
                record[countCell] = (record[countCell] as? Int64 ?? 0) + delta.count
                if let (kind, total) = delta.value {
                    let valueCell = Aggregate.valueCell(index)
                    record[valueCell] = (record[valueCell] as? Double).map { kind.combine($0, total) } ?? total
                }
                if let squares = delta.squares {
                    let squareCell = Aggregate.squareCell(index)
                    record[squareCell] = (record[squareCell] as? Double ?? 0) + squares
                }
            }
            do {
                try await database.write(record: record)
                return
            } catch let conflict as RecordConflictError {
                record = conflict.serverRecord
            }
        }
        throw RecordConflictError(serverRecord: record)
    }

    private func lookup(entity: String, view: String, group: String, day: Date, shard: Int?) async throws -> CKRecord {
        var components = [entity, view, group, "\(day.millisecondsSince1970)"]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        let recordID = CKRecord.ID(recordName: "grid-" + contentDigest(of: components))
        if let existing = try await database.fetchRecord(id: recordID) {
            return existing
        }
        if shard != nil {
            let record = CKRecord(recordType: Aggregate.recordType, recordID: recordID)
            record["entity"] = entity
            record["view"] = view
            record["group_key"] = group
            record["date"] = day
            return record
        }

        let query = ckQuery(
            Aggregate.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "view", op: .equals, value: .string(view)),
                ServerFilter(field: "group_key", op: .equals, value: .string(group)),
                ServerFilter(field: "date", op: .equals, value: .date(day)),
            ])
        if let existing = try await database.allRecords(matching: query).first {
            return existing
        }

        let record = CKRecord(recordType: Aggregate.recordType, recordID: recordID)
        record["entity"] = entity
        record["view"] = view
        record["group_key"] = group
        record["date"] = day
        return record
    }
}

enum Aggregate {
    static let recordType = "Aggregate"

    static let cellCount = 64
    static let squareOffset = 32

    /// How many cells of each half of a row can carry a value.
    ///
    /// The widest period a bucket addresses is a 31-day month, so a cell past
    /// the 31st of either half never carries one and the schema declares none.
    /// Histogram counts still span every cell.
    ///
    static let valueCellCount = 31

    private static let countCells = (0..<cellCount).map { String(format: "c_%02d", $0) }
    private static let valueCells = (0..<cellCount).map { String(format: "f_%02d", $0) }

    static func countCell(_ index: Int) -> String { countCells[index] }
    static func valueCell(_ index: Int) -> String { valueCells[index] }
    static func squareCell(_ index: Int) -> String { valueCells[index + squareOffset] }

    /// The value cells of a cell range that the schema declares.
    static func valueKeys(_ cells: Range<Int>) -> [String] {
        cells.filter { $0 % squareOffset < valueCellCount }.map(valueCell)
    }
}
