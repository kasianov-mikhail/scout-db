//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

private let baseBackoff = 0.1
private let maxBackoff = 2.0

func conflictBackoff(attempt: Int) -> Duration {
    let window = min(maxBackoff, baseBackoff * pow(2, Double(attempt - 1)))
    return .seconds(Double.random(in: 0..<window))
}

struct VectorAggregator {
    let database: any CloudDatabase
    let aggregates: [AggregateDefinition]
    let slots: VectorCache
    let maxRetry = 6
    let growthThreshold = 3

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord]) async throws {
        guard let entity = (new.first ?? old.first)?.entity else {
            return
        }

        let plans = try await plans(of: entity)

        let deltas = aggregates.deltas(removing: old, adding: new, at: Date(), spread: plans)

        let opened = try await VectorLoader(
            database: database,
            slots: slots
        )
        .open(deltas)

        try await VectorIndexWriter(database: database).note(opened.cold)

        var pending = opened.pending
        var lost: [CKRecord.ID: Int] = [:]

        for attempt in 0..<maxRetry {
            if attempt > 0 {
                try await Task.sleep(for: conflictBackoff(attempt: attempt))
            }

            for entry in pending.values {
                entry.delta.apply(to: entry.record)
            }

            var retry: [CKRecord.ID: VectorLoader.Pending] = [:]

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
                        lost[id, default: 0] += 1

                        if let entry = pending[id] {
                            retry[id] = VectorLoader.Pending(
                                record: conflict.serverRecord,
                                delta: entry.delta,
                                slot: entry.slot
                            )
                        }
                    }
                }
            }

            guard retry.count > 0 else {
                pending = [:]
                break
            }
            pending = retry
        }

        let contended = lost.filter { $0.value >= growthThreshold }
            .compactMap { opened.pending[$0.key]?.slot }

        try await spread(contended, plans)

        if let stranded = pending.values.first {
            throw RecordConflictError(serverRecord: stranded.record)
        }
    }

    private func plans(of entity: String) async throws -> ShardPlans {
        let heads = aggregates.map {
            (name: $0.name, floor: $0.shards, id: VectorIndex(entity: entity, aggregate: $0.name, week: nil).recordID)
        }

        var pages: [CKRecord.ID: IndexPage] = [:]
        var cold: [CKRecord.ID] = []

        for head in heads {
            if let cached = await slots.record(head.id) {
                pages[head.id] = cached.indexPage
            } else {
                cold.append(head.id)
            }
        }

        if cold.count > 0 {
            let ids = cold.sorted { $0.recordName < $1.recordName }

            for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
                await slots.keep(record)
                pages[record.recordID] = record.indexPage
            }
        }

        return ShardPlans(
            uniqueKeysWithValues: heads.map {
                ($0.name, ShardPlan(floor: $0.floor, grown: pages[$0.id]?.shards ?? [:]))
            }
        )
    }

    private func spread(_ contended: [VectorSlot], _ plans: ShardPlans) async throws {
        var raised: [VectorIndex: [String: Int]] = [:]

        for slot in contended {
            let index = slot.index.head
            let key = String(slot.week.millisecondsSince1970)
            let standing = raised[index]?[key] ?? plans[slot.aggregate]?.count(for: slot.week) ?? 1

            raised[index, default: [:]][key] = standing * 2
        }

        guard raised.count > 0 else {
            return
        }

        try await VectorIndexWriter(database: database)
            .write(raised.mapValues { IndexPage(weeks: [], groups: [], shards: $0) })

        for index in raised.keys {
            await slots.forget(index.recordID)
        }
    }
}
