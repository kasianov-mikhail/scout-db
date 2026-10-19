//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

typealias Deltas = [VectorSlot: VectorDelta]

struct VectorDelta {
    let kind: Metric
    var cells: [Int: Double] = [:]

    var isNoop: Bool {
        kind.isReversible ? cells.values.allSatisfy { $0 == 0 } : cells.isEmpty
    }

    var inverse: VectorDelta {
        guard kind.isReversible else {
            return VectorDelta(kind: kind)
        }
        return VectorDelta(kind: kind, cells: cells.mapValues(-))
    }

    func apply(to record: CKRecord) {
        for (hour, value) in cells {
            let key = VectorSlot.cellKeys[hour]
            record[key] = kind.combine(record[key] as? Double, value)
        }
    }
}
