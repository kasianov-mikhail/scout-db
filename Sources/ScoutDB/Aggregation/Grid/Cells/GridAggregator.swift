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
    let slots: SlotCache
    let maxRetry = 3
    let maxBatch = 400

    init(database: any CloudDatabase, slots: SlotCache = SlotCache()) {
        self.database = database
        self.slots = slots
    }

    func record(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await rebalance(removing: [], adding: batch, using: definition)
    }

    func remove(_ batch: [EntityRecord], using definition: EntityDefinition) async throws {
        try await rebalance(removing: batch, adding: [], using: definition)
    }

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord], using definition: EntityDefinition)
        async throws
    {
        var merged = deltas(for: old, using: definition, adding: false)
        for (slot, delta) in deltas(for: new, using: definition, adding: true) {
            merged[slot, default: CellDelta()].merge(delta)
        }
        var live: [GridSlot: CellDelta] = [:]
        for (slot, delta) in merged where !delta.isNoop() {
            live[slot] = delta
        }
        try await apply(live)
    }

    private func deltas(for batch: [EntityRecord], using definition: EntityDefinition, adding: Bool) -> [GridSlot:
        CellDelta]
    {
        let sign: Int64 = adding ? 1 : -1
        var deltas: [GridSlot: CellDelta] = [:]

        for entityRecord in batch {
            for view in definition.views ?? [] {
                let group = view.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
                let shard = view.shards.map { Self.shard(of: entityRecord.uuid, among: $0) }
                let slot = GridSlot(entity: entityRecord.entity, view: view.name, group: group, shard: shard)

                var delta = deltas[slot] ?? CellDelta()
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
                deltas[slot] = delta
            }
        }
        return deltas
    }

    static func shard(of uuid: String, among count: Int) -> Int {
        Int(uuid.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
    }

    private struct Pending {
        var record: CKRecord
        var delta: CellDelta
    }

    private func apply(_ deltas: [GridSlot: CellDelta]) async throws {
        guard deltas.count > 0 else {
            return
        }
        var pending = try await open(deltas)

        for _ in 0..<maxRetry {
            for entry in pending.values {
                entry.record.fold(entry.delta)
            }
            var retry: [CKRecord.ID: CKRecord] = [:]
            for chunk in Array(pending.values).chunked(into: maxBatch) {
                for (id, result) in try await database.saveIfUnchanged(chunk.map(\.record)) {
                    switch result {
                    case .success(let saved):
                        await slots.keep(saved)
                    case .failure(let error):
                        guard let conflict = RecordConflictError(error) else {
                            throw error
                        }
                        await slots.keep(conflict.serverRecord)
                        retry[id] = conflict.serverRecord
                    }
                }
            }
            guard retry.count > 0 else {
                return
            }
            pending = pending.filter { retry[$0.key] != nil }
            for (id, record) in retry {
                pending[id]?.record = record
            }
        }
        guard let stranded = pending.values.first else {
            return
        }
        throw RecordConflictError(serverRecord: stranded.record)
    }

    private func open(_ deltas: [GridSlot: CellDelta]) async throws -> [CKRecord.ID: Pending] {
        var pending: [CKRecord.ID: Pending] = [:]
        var cold: [(id: CKRecord.ID, slot: GridSlot, delta: CellDelta)] = []
        for (slot, delta) in deltas {
            let id = slot.recordID
            if let cached = await slots.record(id) {
                pending[id] = Pending(record: cached, delta: delta)
            } else {
                cold.append((id, slot, delta))
            }
        }
        guard cold.count > 0 else {
            return pending
        }

        var served: [CKRecord.ID: CKRecord] = [:]
        let ids = cold.map(\.id).sorted { $0.recordName < $1.recordName }
        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatch) {
            served[record.recordID] = record
        }
        for entry in cold {
            var record = served[entry.id]
            if record == nil, entry.slot.isRenamed {
                record = try await adopt(entry.slot)
            }
            let resolved = record ?? entry.slot.blank(named: entry.id)
            pending[resolved.recordID] = Pending(record: resolved, delta: entry.delta)
        }
        return pending
    }

    private func adopt(_ slot: GridSlot) async throws -> CKRecord? {
        let query = CKQuery(
            recordType: GridSlot.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(slot.entity)),
                ServerFilter(field: "view", op: .equals, value: .string(slot.view)),
                ServerFilter(field: "group_key", op: .equals, value: .string(slot.group)),
                ServerFilter(field: "date", op: .equals, value: .date(GridSlot.date)),
            ]
        )
        return try await database.allRecords(matching: query).first
    }
}

extension CKRecord {
    fileprivate func fold(_ delta: CellDelta) {
        setCellCount(cellCount + delta.count)
        if let (kind, total) = delta.value {
            setCellValue(cellValue.map { kind.combine($0, total) } ?? total)
        }
    }
}
