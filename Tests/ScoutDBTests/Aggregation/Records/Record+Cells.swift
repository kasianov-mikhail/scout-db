//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

@testable import ScoutDB

extension CKRecord {
    func cells(folding kind: Metric = .sum) -> Double? {
        kind.fold(GridCell.keys.compactMap { self[$0] as? Double })
    }

    subscript(cell cell: GridCell) -> Double? {
        get { self[cell.key] as? Double }
        set { self[cell.key] = newValue }
    }

    func reset(cellsTo value: Double, at cell: GridCell = GridCell(day: 0, hour: 0)) {
        for key in GridCell.keys where self[key] != nil {
            self[key] = nil
        }
        self[cell: cell] = value
    }
}
