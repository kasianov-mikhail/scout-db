//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension CKRecord {
    static let countCell = "c_00"
    static let valueCell = "f_00"
    static let squareCell = "f_32"

    var cellCount: Int64 {
        self[Self.countCell] as? Int64 ?? 0
    }

    var cellValue: Double? {
        self[Self.valueCell] as? Double
    }

    var cellSquare: Double? {
        self[Self.squareCell] as? Double
    }

    func setCellCount(_ count: Int64) {
        self[Self.countCell] = count
    }

    func setCellValue(_ value: Double?) {
        self[Self.valueCell] = value
    }

    func setCellSquare(_ square: Double) {
        self[Self.squareCell] = square
    }
}
