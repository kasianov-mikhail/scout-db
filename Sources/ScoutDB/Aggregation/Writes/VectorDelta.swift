//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorDelta<Holder: Vector> {
    let kind: Metric
    var cells: [Int: Holder.Cell] = [:]

    var isNoop: Bool {
        kind.isReversible ? cells.values.allSatisfy { $0 == .zero } : cells.isEmpty
    }

    func reversed() -> Self {
        guard kind.isReversible else {
            return Self(kind: kind)
        }
        return Self(kind: kind, cells: cells.mapValues(-))
    }

    func apply(to record: CKRecord) {
        for (hour, value) in cells {
            let key = Holder.cellKeys[hour]

            if let stored = Holder.Cell.cell(of: record, at: key) {
                kind.combine(stored, value).store(in: record, at: key)
            } else {
                value.store(in: record, at: key)
            }
        }
    }
}
