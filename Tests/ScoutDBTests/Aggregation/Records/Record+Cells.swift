//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

@testable import ScoutDB

private let cellKeys = DoubleVector.cellKeys

extension CKRecord {
    var counts: Bool {
        recordType == IntVector.recordType
    }

    func cells(folding kind: Metric = .sum) -> Double? {
        counts
            ? kind.fold(cellKeys.compactMap { Int64.cell(of: self, at: $0) })?.scalar
            : kind.fold(cellKeys.compactMap { Double.cell(of: self, at: $0) })?.scalar
    }

    subscript(cell hour: Int) -> Double? {
        get {
            counts
                ? Int64.cell(of: self, at: cellKeys[hour])?.scalar
                : Double.cell(of: self, at: cellKeys[hour])
        }
        set {
            guard let newValue else {
                self[cellKeys[hour]] = nil
                return
            }
            if counts {
                Int64(newValue).store(in: self, at: cellKeys[hour])
            } else {
                newValue.store(in: self, at: cellKeys[hour])
            }
        }
    }

    func reset(cellsTo value: Double, at hour: Int = 0) {
        for key in cellKeys where self[key] != nil {
            self[key] = nil
        }
        self[cell: hour] = value
    }
}
