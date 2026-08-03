//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridDelta {
    var count: Int64 = 0
    var total: GridTotal?

    func reversed() -> GridDelta {
        guard let total, total.kind.isReversible else {
            return GridDelta(count: -count)
        }
        return GridDelta(count: -count, total: -total)
    }

    static func + (lhs: GridDelta, rhs: GridDelta) -> GridDelta {
        let count = lhs.count + rhs.count

        guard let left = lhs.total, let right = rhs.total else {
            return GridDelta(count: count, total: lhs.total ?? rhs.total)
        }
        return GridDelta(count: count, total: left + right)
    }

    func apply(to record: CKRecord) {
        record[CKRecord.countCell] = (record[CKRecord.countCell] as? Int64 ?? 0) + count

        guard let total else {
            return
        }

        if let cell = record[CKRecord.valueCell] as? Double {
            record[CKRecord.valueCell] = total.kind.combine(cell, total.value)
        } else {
            record[CKRecord.valueCell] = total.value
        }
    }
}
