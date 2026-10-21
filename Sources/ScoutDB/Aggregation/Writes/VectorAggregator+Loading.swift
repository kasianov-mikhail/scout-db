//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct PendingVector {
    var record: CKRecord
    let delta: VectorDelta
    let slot: VectorSlot
}

extension VectorAggregator {
    struct Opened {
        let pending: [CKRecord.ID: PendingVector]
        let cold: [VectorSlot]
    }

    func open(deltas: Deltas) async throws -> Opened {
        let served = try await slots.records(ids: deltas.keys.map(\.recordID), database: database)

        var pending: [CKRecord.ID: PendingVector] = [:]
        var cold: [VectorSlot] = []

        for (slot, delta) in deltas {
            let id = slot.recordID
            let record = served.records[id] ?? CKRecord(recordType: VectorSlot.recordType, recordID: id)
            pending[id] = PendingVector(record: record, delta: delta, slot: slot)

            if served.cold.contains(id) {
                cold.append(slot)
            }
        }

        return Opened(pending: pending, cold: cold)
    }
}
