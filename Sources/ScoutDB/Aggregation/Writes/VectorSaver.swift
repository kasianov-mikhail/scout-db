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

struct VectorSaver {
    let database: any CloudDatabase
    let slots: VectorCache
    let maxRetry = 6

    struct Outcome {
        let lost: [VectorSlot: Int]
        let stranded: CKRecord?
    }

    func save(pending: [CKRecord.ID: PendingVector]) async throws -> Outcome {
        var pending = pending
        var lost: [VectorSlot: Int] = [:]

        for attempt in 0..<maxRetry {
            if attempt > 0 {
                try await Task.sleep(for: conflictBackoff(attempt: attempt))
            }

            for entry in pending.values {
                entry.delta.apply(record: entry.record)
            }

            var retry: [CKRecord.ID: PendingVector] = [:]

            for chunk in Array(pending.values).chunked(size: maxBatchSize) {
                for (id, result) in try await database.saveIfUnchanged(chunk.map(\.record)) {
                    switch result {
                    case .success(let saved):
                        await slots.keep(record: saved)
                    case .failure(let error):
                        guard let conflict = RecordConflictError(error: error) else {
                            throw error
                        }
                        await slots.keep(record: conflict.serverRecord)

                        if let entry = pending[id] {
                            lost[entry.slot, default: 0] += 1
                            retry[id] = PendingVector(
                                record: conflict.serverRecord,
                                delta: entry.delta,
                                slot: entry.slot
                            )
                        }
                    }
                }
            }

            guard !retry.isEmpty else {
                pending = [:]
                break
            }
            pending = retry
        }

        return Outcome(lost: lost, stranded: pending.values.first?.record)
    }
}
