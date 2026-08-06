//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridDelta {
    let kind: Metric
    var cells: [GridCell: Double] = [:]

    var isNoop: Bool {
        kind.isReversible ? cells.values.allSatisfy { $0 == 0 } : cells.isEmpty
    }

    func reversed() -> GridDelta {
        guard kind.isReversible else {
            return GridDelta(kind: kind)
        }
        return GridDelta(kind: kind, cells: cells.mapValues(-))
    }

    func apply(to record: CKRecord) {
        for (cell, value) in cells {
            let key = cell.key

            if let stored = record[key] as? Double {
                record[key] = kind.combine(stored, value)
            } else {
                record[key] = value
            }
        }
    }
}
