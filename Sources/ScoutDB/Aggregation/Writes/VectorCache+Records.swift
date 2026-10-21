//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct CachedRecords {
    let records: [CKRecord.ID: CKRecord]
    let cold: Set<CKRecord.ID>

    var fetched: [CKRecord] {
        cold.compactMap { records[$0] }
    }
}

extension VectorCache {
    func records(ids: [CKRecord.ID], database: any CloudDatabase) async throws -> CachedRecords {
        var records: [CKRecord.ID: CKRecord] = [:]
        var cold: Set<CKRecord.ID> = []

        for id in ids {
            if let cached = record(id: id) {
                records[id] = cached
            } else {
                cold.insert(id)
            }
        }

        for record in try await database.fetchRecords(ids: Array(cold), batchSize: maxBatchSize) {
            records[record.recordID] = record
        }

        return CachedRecords(records: records, cold: cold)
    }
}
