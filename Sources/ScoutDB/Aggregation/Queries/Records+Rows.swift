//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension [CKRecord] {
    func vectorRows(folding kind: Metric, where include: (String) -> Bool = { _ in true }) -> [String: Double] {
        var rows: [String: Double] = [:]

        for record in self {
            guard let key = record[VectorSlot.Key.group] as? String, include(key) else {
                continue
            }
            guard let value = kind.fold(record.cells) else {
                continue
            }
            rows[key] = rows[key].map { kind.combine($0, value) } ?? value
        }

        return rows
    }
}

extension CKRecord {
    fileprivate var cells: [Double] {
        allKeys().compactMap { key in
            key.hasPrefix("c_") ? self[key] as? Double : nil
        }
    }
}
