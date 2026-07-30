//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

actor SlotCache {
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var usage: [CKRecord.ID: Int64] = [:]
    private var clock: Int64 = 0
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func record(_ id: CKRecord.ID) -> CKRecord? {
        guard let record = records[id] else {
            return nil
        }
        touch(id)
        return record.duplicate()
    }

    func keep(_ record: CKRecord) {
        records[record.recordID] = record.duplicate()
        touch(record.recordID)
        evict()
    }

    func forget(_ id: CKRecord.ID) {
        records[id] = nil
        usage[id] = nil
    }

    private func touch(_ id: CKRecord.ID) {
        clock += 1
        usage[id] = clock
    }

    private func evict() {
        guard records.count > limit + limit / 10 else {
            return
        }
        for victim in records.keys.sorted(by: { usage[$0] ?? 0 < usage[$1] ?? 0 }).prefix(records.count - limit) {
            records[victim] = nil
            usage[victim] = nil
        }
    }
}
