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

        guard deltas.count > 0 else {
            return
        }

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

        try await spread(lost, of: entity, over: plans, at: opened.pending)

        if let stranded = pending.values.first {
            throw RecordConflictError(serverRecord: stranded.record)
        }
    }

    /// What each aggregate's weeks have grown to, read off the head index the
    /// reader already consults and kept in the slot cache beside the vectors.
    ///
    /// A stale answer is safe and needs no agreement between writers: a count
    /// only rises, so a writer still on the old one files into a shard the
    /// reader covers anyway. Losing races is what refreshes it.
    ///
    private func plans(of entity: String) async throws -> ShardPlans {
        let heads = aggregates.map {
            (name: $0.name, floor: $0.shards, id: VectorIndex(entity: entity, aggregate: $0.name, week: nil).recordID)
        }

        var pages: [CKRecord.ID: VectorIndex.Page] = [:]
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
            uniqueKeysWithValues: heads.map { ($0.name, ShardPlan(floor: $0.floor, page: pages[$0.id])) }
        )
    }

    /// Doubles the week behind every slot that lost ``growthThreshold`` races,
    /// so the next writer to reach it spreads over twice as many records.
    ///
    /// The signal is the contention itself rather than an outright failure —
    /// a slot that fought its way through on the fifth attempt has already
    /// shown the group is hot, and waiting for a write to fail outright would
    /// spread it a burst too late.
    ///
    private func spread(
        _ lost: [CKRecord.ID: Int],
        of entity: String,
        over plans: ShardPlans,
        at pending: [CKRecord.ID: VectorLoader.Pending]
    ) async throws {
        var raised: [VectorIndex: ShardPlan] = [:]

        for (id, races) in lost where races >= growthThreshold {
            guard let slot = pending[id]?.slot else {
                continue
            }

            let index = VectorIndex(entity: entity, aggregate: slot.aggregate, week: nil)
            let plan = raised[index] ?? plans[slot.aggregate] ?? ShardPlan(floor: nil)

            raised[index] = plan.doubling(slot.week)
        }

        guard raised.count > 0 else {
            return
        }

        try await VectorIndexWriter(database: database)
            .write(raised.mapValues { VectorIndex.Page(weeks: [], groups: [], shards: $0.stored) })

        for index in raised.keys {
            await slots.forget(index.recordID)
        }
    }
}
