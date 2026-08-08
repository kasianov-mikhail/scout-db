//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension [VectorReader.Row] {
    func vectorRows(folding kind: Metric, where include: ((String) -> Bool)?) -> [String: Double] {
        var rows: [String: Double] = [:]

        for (key, _, record) in self {
            guard include?(key) != false, let value = kind.fold(record.cells) else {
                continue
            }
            rows[key] = rows[key].map { kind.combine($0, value) } ?? value
        }

        return rows
    }

    // A cell is an hour, so a row unfolds into the hours of its week that the
    // range covers. An hour nothing wrote has no cell, and stays out of the
    // result rather than reading as a zero.
    func vectorCells(folding kind: Metric, in range: Range<Date>) -> [SeriesCell: Double] {
        var cells: [SeriesCell: Double] = [:]

        for (key, week, record) in self {
            for hour in 0..<Date.hoursPerWeek {
                let date = week.hour(hour)

                guard range.contains(date), let value = record[VectorSlot.cellKeys[hour]] as? Double else {
                    continue
                }
                let cell = SeriesCell(group: key, date: date)
                cells[cell] = cells[cell].map { kind.combine($0, value) } ?? value
            }
        }

        return cells
    }
}

struct SeriesCell: Hashable {
    let group: String
    let date: Date
}

extension CKRecord {
    fileprivate var cells: [Double] {
        allKeys().compactMap { key in
            key.hasPrefix("c_") ? self[key] as? Double : nil
        }
    }
}
