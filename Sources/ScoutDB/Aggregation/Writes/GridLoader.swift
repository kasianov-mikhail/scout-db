//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridLoader {
    let database: any CloudDatabase
    let slots: GridCache

    struct Pending {
        var record: CKRecord
        let delta: GridDelta
    }

    func open(_ deltas: [GridSlot: GridDelta]) async throws -> [CKRecord.ID: Pending] {
        var pending: [CKRecord.ID: Pending] = [:]
        var cold: [(id: CKRecord.ID, slot: GridSlot, delta: GridDelta)] = []

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

        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            served[record.recordID] = record
        }

        for (id, slot, delta) in cold {
            pending[id] = Pending(record: served[id] ?? slot.blank(named: id), delta: delta)
        }

        return pending
    }
}
