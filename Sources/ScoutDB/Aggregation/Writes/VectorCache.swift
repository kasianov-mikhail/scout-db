//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

actor VectorCache {
    private var entries: [CKRecord.ID: Entry] = [:]
    private var clock: Int64 = 0
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func record(_ id: CKRecord.ID) -> CKRecord? {
        guard let entry = entries[id] else {
            return nil
        }
        entries[id] = Entry(record: entry.record, usage: tick())
        return entry.record.duplicate()
    }

    func keep(_ record: CKRecord) {
        entries[record.recordID] = Entry(record: record.duplicate(), usage: tick())
        evict()
    }

    private func tick() -> Int64 {
        clock += 1
        return clock
    }

    private func evict() {
        guard entries.count > limit + limit / 10 else {
            return
        }
        for victim in entries.values.sorted().prefix(entries.count - limit) {
            entries[victim.record.recordID] = nil
        }
    }
}

private struct Entry: Comparable {
    let record: CKRecord
    let usage: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.usage < rhs.usage
    }
}
