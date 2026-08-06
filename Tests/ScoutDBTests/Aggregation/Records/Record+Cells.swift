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
        kind.fold(DoubleVector.cellKeys.compactMap { self[$0] as? Double })
    }

    subscript(cell hour: Int) -> Double? {
        get { self[DoubleVector.cellKeys[hour]] as? Double }
        set { self[DoubleVector.cellKeys[hour]] = newValue }
    }

    func reset(cellsTo value: Double, at hour: Int = 0) {
        for key in DoubleVector.cellKeys where self[key] != nil {
            self[key] = nil
        }
        self[cell: hour] = value
    }
}
