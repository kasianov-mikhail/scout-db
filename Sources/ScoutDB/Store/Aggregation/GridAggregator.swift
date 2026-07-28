//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridAggregator {
    struct CellRange: Sendable {
        let view: AggregateView
        let group: String
        let period: Date
        let index: Int
    }

    let database: any CloudDatabase
    let slots: SlotCache
    let recompute: (@Sendable (CellRange, EntityDefinition) async throws -> Double?)?
    let maxRetry = 3
    let maxBatch = 400

    init(
        database: any CloudDatabase, slots: SlotCache = SlotCache(),
        recompute: (@Sendable (CellRange, EntityDefinition) async throws -> Double?)? = nil
    ) {
        self.database = database
        self.slots = slots
        self.recompute = recompute
    }

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
        var live: [GridSlot: [Int: CellDelta]] = [:]
        for (slot, cells) in merged {
            let settled = cells.filter { !$0.value.isNoop(recomputing: recomputes(slot.view, in: definition)) }
            guard settled.count > 0 else { continue }
            live[slot] = settled
        }
        try await apply(live, using: definition)
    }

    private func recomputes(_ view: String, in definition: EntityDefinition) -> Bool {
        guard recompute != nil, let view = definition.view(named: view), view.exact == true, let metric = view.metric else { return false }
        return metric.kind != .sum
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
        if let (kind, total) = rhs.removed {
            merged.removed = (kind, merged.removed.map { kind.combine($0.total, total) } ?? total)
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
                    } else {
                        delta.removed = (kind, delta.removed.map { kind.combine($0.total, value) } ?? value)
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
        var removed: (kind: AggregateView.Metric, total: Double)?

        func isNoop(recomputing: Bool) -> Bool {
            guard count == 0, (squares ?? 0) == 0 else { return false }
            guard !recomputing || removed == nil else { return false }
            guard let (kind, total) = value else { return true }
            guard kind != .sum else { return total == 0 }
            guard let removed else { return false }
            return kind.combine(removed.total, total) == removed.total
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

    private struct Pending {
        let slot: GridSlot
        var record: CKRecord
        var cells: [Int: CellDelta]
    }

    private func apply(_ deltas: [GridSlot: [Int: CellDelta]], using definition: EntityDefinition) async throws {
        guard deltas.count > 0 else { return }
        var pending = try await open(deltas)
        let exact = try await recomputed(&pending, using: definition)

        for _ in 0..<maxRetry {
            for entry in pending.values {
                Self.fold(entry.cells, into: entry.record)
                Self.settle(exact[entry.record.recordID], into: entry.record)
            }
            var retry: [CKRecord.ID: CKRecord] = [:]
            for chunk in Array(pending.values).chunked(into: maxBatch) {
                for (id, result) in try await database.saveIfUnchanged(chunk.map(\.record)) {
                    switch result {
                    case .success(let saved):
                        await slots.keep(saved)
                    case .failure(let error):
                        guard let slot = pending[id]?.slot else { throw error }
                        if let conflict = RecordConflictError(error) {
                            await slots.keep(conflict.serverRecord)
                            retry[id] = conflict.serverRecord
                        } else if Self.vanished(error) {
                            await slots.forget(id)
                            retry[id] = Self.blank(slot, named: id)
                        } else {
                            throw error
                        }
                    }
                }
            }
            guard retry.count > 0 else { return }
            pending = pending.filter { retry[$0.key] != nil }
            for (id, record) in retry {
                pending[id]?.record = record
            }
        }
        guard let stranded = pending.values.first else { return }
        throw RecordConflictError(serverRecord: stranded.record)
    }

    private func recomputed(_ pending: inout [CKRecord.ID: Pending], using definition: EntityDefinition) async throws -> [CKRecord.ID: [Int: Double?]] {
        guard let recompute else { return [:] }
        var exact: [CKRecord.ID: [Int: Double?]] = [:]
        for (id, entry) in pending {
            guard let view = definition.view(named: entry.slot.view), view.exact == true, let metric = view.metric, metric.kind != .sum else { continue }
            var settled: [Int: Double?] = [:]
            for (index, delta) in entry.cells {
                guard let removed = delta.removed, let stored = entry.record[Aggregate.valueCell(index)] as? Double, stored == removed.total else {
                    continue
                }
                settled[index] = try await recompute(
                    CellRange(view: view, group: entry.slot.group, period: entry.slot.day, index: index), definition)
                pending[id]?.cells[index]?.value = nil
                pending[id]?.cells[index]?.removed = nil
            }
            guard settled.count > 0 else { continue }
            exact[id] = settled
        }
        return exact
    }

    private static func settle(_ cells: [Int: Double?]?, into record: CKRecord) {
        guard let cells else { return }
        for (index, value) in cells {
            if let value {
                record[Aggregate.valueCell(index)] = value
            } else {
                record[Aggregate.valueCell(index)] = nil
            }
        }
    }

    private func open(_ deltas: [GridSlot: [Int: CellDelta]]) async throws -> [CKRecord.ID: Pending] {
        var pending: [CKRecord.ID: Pending] = [:]
        var cold: [(id: CKRecord.ID, slot: GridSlot, cells: [Int: CellDelta])] = []
        for (slot, cells) in deltas {
            let id = Self.recordID(of: slot)
            if let cached = await slots.record(id) {
                pending[id] = Pending(slot: slot, record: cached, cells: cells)
            } else {
                cold.append((id, slot, cells))
            }
        }
        guard cold.count > 0 else { return pending }

        var served: [CKRecord.ID: CKRecord] = [:]
        let ids = cold.map(\.id).sorted { $0.recordName < $1.recordName }
        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatch) {
            served[record.recordID] = record
        }
        for entry in cold {
            var record = served[entry.id]
            if record == nil, Self.renamed(entry.slot) {
                record = try await adopt(entry.slot)
            }
            let resolved = record ?? Self.blank(entry.slot, named: entry.id)
            pending[resolved.recordID] = Pending(slot: entry.slot, record: resolved, cells: entry.cells)
        }
        return pending
    }

    private func adopt(_ slot: GridSlot) async throws -> CKRecord? {
        let query = ckQuery(
            Aggregate.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(slot.entity)),
                ServerFilter(field: "view", op: .equals, value: .string(slot.view)),
                ServerFilter(field: "group_key", op: .equals, value: .string(slot.group)),
                ServerFilter(field: "date", op: .equals, value: .date(slot.day)),
            ])
        return try await database.allRecords(matching: query).first
    }

    private static func fold(_ cells: [Int: CellDelta], into record: CKRecord) {
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
    }

    private static func components(of slot: GridSlot) -> [String] {
        var components = [slot.entity, slot.view, slot.group, "\(slot.day.millisecondsSince1970)"]
        if let shard = slot.shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    private static func recordID(of slot: GridSlot) -> CKRecord.ID {
        CKRecord.ID(recordName: "grid-" + contentDigest(of: components(of: slot)))
    }

    private static func renamed(_ slot: GridSlot) -> Bool {
        slot.shard == nil && escapesSeparators(components(of: slot))
    }

    private static func blank(_ slot: GridSlot, named id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: Aggregate.recordType, recordID: id)
        record["entity"] = slot.entity
        record["view"] = slot.view
        record["group_key"] = slot.group
        record["date"] = slot.day
        return record
    }

    private static func vanished(_ error: any Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }
}

enum Aggregate {
    static let recordType = "Aggregate"

    static let cellCount = 64
    static let squareOffset = 32

    static let valueCellCount = 31

    private static let countCells = (0..<cellCount).map { String(format: "c_%02d", $0) }
    private static let valueCells = (0..<cellCount).map { String(format: "f_%02d", $0) }

    static func countCell(_ index: Int) -> String { countCells[index] }
    static func valueCell(_ index: Int) -> String { valueCells[index] }
    static func squareCell(_ index: Int) -> String { valueCells[index + squareOffset] }

    static func valueKeys(_ cells: Range<Int>) -> [String] {
        cells.filter { $0 % squareOffset < valueCellCount }.map(valueCell)
    }
}
