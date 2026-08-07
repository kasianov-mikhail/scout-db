//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorAggregator {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let aggregates: [AggregateDefinition]
    let slots: VectorCache
    let maxRetry = 3

    init(
        database: any CloudDatabase,
        definition: EntityDefinition,
        aggregates: [AggregateDefinition]? = nil,
        slots: VectorCache = VectorCache()
    ) {
        self.database = database
        self.definition = definition
        self.aggregates = aggregates ?? definition.aggregates
        self.slots = slots
    }

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord]) async throws {
        let deltas = definition.deltas(
            aggregates,
            removing: old,
            adding: new,
            at: Date()
        )

        async let counted: Void = fold(deltas.integers)
        async let measured: Void = fold(deltas.doubles)

        _ = try await (counted, measured)
    }

    private func fold<Holder: Vector>(_ deltas: [VectorSlot<Holder>: VectorDelta<Holder>]) async throws {
        guard deltas.count > 0 else {
            return
        }

        let opened = try await VectorLoader<Holder>(
            database: database,
            slots: slots
        )
        .open(deltas)

        try await VectorIndexWriter(database: database).note(opened.cold)

        var pending = opened.pending

        for _ in 0..<maxRetry {
            for entry in pending.values {
                entry.delta.apply(to: entry.record)
            }

            var retry: [CKRecord.ID: VectorLoader<Holder>.Pending] = [:]

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

                        if let delta = pending[id]?.delta {
                            retry[id] = VectorLoader<Holder>.Pending(
                                record: conflict.serverRecord,
                                delta: delta
                            )
                        }
                    }
                }
            }

            guard retry.count > 0 else {
                return
            }
            pending = retry
        }

        if let stranded = pending.values.first {
            throw RecordConflictError(serverRecord: stranded.record)
        }
    }
}
