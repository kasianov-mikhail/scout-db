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
    let aggregates: [AggregateDefinition]
    let slots: GridCache
    let maxRetry = 3

    init(database: any CloudDatabase, aggregates: [AggregateDefinition], slots: GridCache = GridCache()) {
        self.database = database
        self.aggregates = aggregates
        self.slots = slots
    }

    func rebalance(removing old: [EntityRecord], adding new: [EntityRecord]) async throws {
        let deltas = aggregates.deltas(
            removing: old,
            adding: new,
            at: Date()
        )

        guard deltas.count > 0 else {
            return
        }

        var pending = try await GridLoader(
            database: database,
            slots: slots
        )
        .open(deltas)

        for _ in 0..<maxRetry {
            for entry in pending.values {
                entry.delta.apply(to: entry.record)
            }

            var retry: [CKRecord.ID: GridLoader.Pending] = [:]

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
                            retry[id] = GridLoader.Pending(
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
