//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorLoader {
    let database: any CloudDatabase
    let slots: VectorCache

    struct Pending {
        var record: CKRecord
        let delta: VectorDelta
        let slot: VectorSlot
    }

    struct Opened {
        let pending: [CKRecord.ID: Pending]
        let cold: [VectorSlot]
    }

    func open(_ deltas: Deltas) async throws -> Opened {
        var pending: [CKRecord.ID: Pending] = [:]
        var cold: [(id: CKRecord.ID, slot: VectorSlot, delta: VectorDelta)] = []

        for (slot, delta) in deltas {
            let id = slot.recordID

            if let cached = await slots.record(id) {
                pending[id] = Pending(record: cached, delta: delta, slot: slot)
            } else {
                cold.append((id, slot, delta))
            }
        }

        var served: [CKRecord.ID: CKRecord] = [:]
        let ids = cold.map(\.id).sorted { $0.recordName < $1.recordName }

        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            served[record.recordID] = record
        }

        for (id, slot, delta) in cold {
            let record = served[id] ?? CKRecord(recordType: VectorSlot.recordType, recordID: id)
            pending[id] = Pending(record: record, delta: delta, slot: slot)
        }

        return Opened(pending: pending, cold: cold.map(\.slot))
    }
}
