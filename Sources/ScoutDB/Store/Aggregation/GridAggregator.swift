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

    // Adds the batch's contributions to the views: every write increments its cells.
    func record(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await apply(deltas(for: batch, using: definition, adding: true))
    }

    // Removes the batch's contributions when records are deleted or updated. Count, sum,
    // stats (Σx, Σx²) and histogram cells reverse exactly; a min/max extremum cannot be
    // un-applied without rescanning, so its value cell is left untouched (best-effort) even
    // though its count still decrements. See docs/aggregation.md.
    func remove(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await apply(deltas(for: batch, using: definition, adding: false))
    }

    // Folds the whole batch into per-cell deltas first, so each touched grid record costs
    // one lookup and one write no matter how many records feed it. `adding` flips every
    // reversible delta's sign; a min/max value only accumulates when adding.
    private func deltas(for batch: [EntityRecord], using definition: EntityDefinition, adding: Bool) -> [GridSlot: [Int: CellDelta]] {
        let sign: Int64 = adding ? 1 : -1
        var deltas: [GridSlot: [Int: CellDelta]] = [:]

        for entityRecord in batch where entityRecord.deleted == false {
            guard let dateField = definition.envelopeDate, case .date(let date)? = entityRecord.values[dateField] else { continue }

            for view in definition.views ?? [] {
                let group = view.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""

                if let histogram = view.histogram {
                    guard let value = entityRecord.values[histogram.field]?.scalar else { continue }
                    let slot = GridSlot(entity: entityRecord.entity, view: view.name, group: group, day: EntityCoder.calendar.startOfDay(for: date))
                    let index = histogram.bounds.firstIndex { value < $0 } ?? histogram.bounds.count
                    deltas[slot, default: [:]][index, default: CellDelta()].count += sign
                    continue
                }

                let (period, index) = Self.bucket(view.bucket ?? .hour, for: date)
                let slot = GridSlot(entity: entityRecord.entity, view: view.name, group: group, day: period)
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

    // Touched grid slots are distinct records, so their read-modify-write cycles run
    // concurrently; the shared request limiter still bounds the actual CloudKit fan-out.
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
    }

    private struct CellDelta {
        var count: Int64 = 0
        var value: (kind: AggregateView.Metric, total: Double)?
        var squares: Double?
    }

    static func bucket(_ bucket: AggregateView.Bucket, for date: Date) -> (period: Date, index: Int) {
        let calendar = EntityCoder.calendar
        switch bucket {
        case .hour:
            return (calendar.startOfDay(for: date), calendar.component(.hour, from: date))
        case .weekday:
            let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return (week, calendar.component(.weekday, from: date) - 1)
        case .day:
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            return (month, calendar.component(.day, from: date) - 1)
        }
    }

    // A stats view keeps the running sum in f_index and the sum of squares in
    // f_(index + 32); time buckets never exceed index 30, so the halves cannot clash.
    private func apply(_ cells: [Int: CellDelta], to slot: GridSlot) async throws {
        var record = try await lookup(entity: slot.entity, view: slot.view, group: slot.group, day: slot.day)

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

    private func lookup(entity: String, view: String, group: String, day: Date) async throws -> CKRecord {
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

        let digest = contentDigest(of: [entity, view, group, "\(day.millisecondsSince1970)"])
        let record = CKRecord(recordType: Aggregate.recordType, recordID: CKRecord.ID(recordName: "grid-" + digest))
        record["entity"] = entity
        record["view"] = view
        record["group_key"] = group
        record["date"] = day
        return record
    }
}

enum Aggregate {
    static let recordType = "Aggregate"

    // Grid layout: 64 cells per record. Time buckets never exceed index 30 and a
    // stats view keeps its sum of squares `squareOffset` cells above its value, so
    // the two halves cannot clash.
    static let cellCount = 64
    static let squareOffset = 32

    // Per-cell field names. Count cells hold occurrence counts; value cells hold the
    // metric total. Precomputed once — analytics reads touch them up to 128 times
    // per grid record.
    private static let countCells = (0..<cellCount).map { String(format: "c_%02d", $0) }
    private static let valueCells = (0..<cellCount).map { String(format: "f_%02d", $0) }

    static func countCell(_ index: Int) -> String { countCells[index] }
    static func valueCell(_ index: Int) -> String { valueCells[index] }
    static func squareCell(_ index: Int) -> String { valueCells[index + squareOffset] }
}
