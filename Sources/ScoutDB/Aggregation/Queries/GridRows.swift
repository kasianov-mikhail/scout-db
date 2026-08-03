//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension [CKRecord] {
    func gridRows(folding kind: Metric?, where include: (GridRow) -> Bool) -> [String: GridFold] {
        var rows: [String: GridFold] = [:]

        for record in self {
            guard let key = record[CKRecord.groupCell] as? String else {
                continue
            }

            let row = GridRow(
                group: key,
                count: Int(record[CKRecord.countCell] as? Int64 ?? 0),
                value: kind == nil ? nil : record[CKRecord.valueCell] as? Double
            )

            if include(row) {
                rows[key] = (rows[key] ?? .empty).merging(row.fold, folding: kind)
            }
        }

        return rows
    }
}

struct GridRow: Sendable {
    let group: String
    let count: Int
    let value: Double?

    var fold: GridFold {
        GridFold(count: count, value: value)
    }
}

struct GridFold: Sendable {
    let count: Int
    let value: Double?

    static let empty = GridFold(count: 0, value: nil)

    func merging(_ other: GridFold, folding kind: Metric?) -> GridFold {
        var total = value
        if let kind, let value = other.value {
            total = total.map { kind.combine($0, value) } ?? value
        }
        return GridFold(count: count + other.count, value: total)
    }
}
