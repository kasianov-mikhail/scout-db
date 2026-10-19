//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension [VectorRow] {
    func vectorRows(folding kind: Metric) -> [String: Double] {
        Dictionary(grouping: self, by: \.group).compactMapValues {
            kind.fold($0.flatMap(\.record.cells))
        }
    }

    func vectorCells(folding kind: Metric, in range: Range<Date>) -> [SeriesPoint.Key: Double] {
        Dictionary(flatMap { $0.cells(in: range) }, uniquingKeysWith: kind.combine)
    }
}

extension SeriesPoint {
    struct Key: Hashable {
        let group: String
        let date: Date
    }
}

extension CKRecord {
    fileprivate var cells: [Double] {
        allKeys().compactMap { key in
            key.hasPrefix("c_") ? self[key] as? Double : nil
        }
    }
}

extension VectorRow {
    fileprivate func cells(in range: Range<Date>) -> [SeriesPoint.Key: Double] {
        (0..<Date.hoursPerWeek).reduce(into: [:]) { cells, hour in
            let date = week.hour(hour)

            guard range.contains(date), let value = record[VectorSlot.cellKeys[hour]] as? Double else {
                return
            }
            cells[SeriesPoint.Key(group: group, date: date)] = value
        }
    }
}
