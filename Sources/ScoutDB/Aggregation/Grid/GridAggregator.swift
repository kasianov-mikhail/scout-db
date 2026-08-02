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
    let slots: GridCache
    let maxRetry = 3

    init(database: any CloudDatabase, slots: GridCache = GridCache()) {
        self.database = database
        self.slots = slots
    }

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord], using definition: EntityDefinition)
        async throws
    {
        var merged = deltas(for: old, using: definition, adding: false)
        for (slot, delta) in deltas(for: new, using: definition, adding: true) {
            merged[slot, default: GridDelta()].merge(delta)
        }
        var live: [GridSlot: GridDelta] = [:]
        for (slot, delta) in merged where !delta.isNoop() {
            live[slot] = delta
        }
        try await apply(live)
    }

    private func deltas(for batch: [EntityRecord], using definition: EntityDefinition, adding: Bool) -> [GridSlot:
        GridDelta]
    {
        let sign: Int64 = adding ? 1 : -1
        var deltas: [GridSlot: GridDelta] = [:]

        for entityRecord in batch {
            for view in definition.views ?? [] {
                let group = view.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
                let shard = view.shards.map { Self.shard(of: entityRecord.uuid, among: $0) }
                let slot = GridSlot(entity: entityRecord.entity, view: view.name, group: group, shard: shard)

                var delta = deltas[slot] ?? GridDelta()
                delta.count += sign
                if let kind = view.metricKind, let field = view.metricField,
                    let value = entityRecord.values[field]?.scalar
                {
                    delta.kind = kind
                    if adding {
                        delta.value = kind.combine(delta.value, value)
                    } else if kind.isReversible {
                        delta.value = (delta.value ?? 0) - value
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
        var delta: GridDelta
    }

    private struct ColdSlot {
        let slot: GridSlot
        let delta: GridDelta
        let id: CKRecord.ID
    }

    private func apply(_ deltas: [GridSlot: GridDelta]) async throws {
        guard deltas.count > 0 else {
            return
        }
        var pending = try await open(deltas)

        for _ in 0..<maxRetry {
            for entry in pending.values {
                let record = entry.record
                record[CKRecord.countCell] = (record[CKRecord.countCell] as? Int64 ?? 0) + entry.delta.count
                if let kind = entry.delta.kind, let total = entry.delta.value {
                    record[CKRecord.valueCell] = kind.combine(record[CKRecord.valueCell] as? Double, total)
                }
            }
            var retry: [CKRecord.ID: CKRecord] = [:]
            for chunk in Array(pending.values).chunked(into: maxBatchSize) {
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

    private func open(_ deltas: [GridSlot: GridDelta]) async throws -> [CKRecord.ID: Pending] {
        var pending: [CKRecord.ID: Pending] = [:]
        var cold: [ColdSlot] = []
        for (slot, delta) in deltas {
            let id = slot.recordID
            if let cached = await slots.record(id) {
                pending[id] = Pending(record: cached, delta: delta)
            } else {
                cold.append(ColdSlot(slot: slot, delta: delta, id: id))
            }
        }
        guard cold.count > 0 else {
            return pending
        }

        var served: [CKRecord.ID: CKRecord] = [:]
        let ids = cold.map(\.id).sorted { $0.recordName < $1.recordName }
        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
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
        try await database.allRecords(
            matching: .grid(entity: slot.entity, view: slot.view, group: slot.group)
        ).first
    }
}
