//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorRow {
    let group: String
    let week: Date
    let record: CKRecord

    func trimmed(since: Date) -> VectorRow? {
        guard week < since else {
            return self
        }
        guard week.hour(index: Date.hoursPerWeek) > since else {
            return nil
        }

        let trimmed = record.duplicate()
        for hour in 0..<Date.hoursPerWeek where week.hour(index: hour) < since {
            trimmed[VectorSlot.cellKeys[hour]] = nil
        }
        return VectorRow(group: group, week: week, record: trimmed)
    }
}
