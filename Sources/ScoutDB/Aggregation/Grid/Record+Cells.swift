//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension CKRecord {
    static let cellCount = 64
    static let squareOffset = 32
    static let valueCellCount = 31

    private static let countCells = (0..<cellCount).map { String(format: "c_%02d", $0) }
    private static let valueCells = (0..<cellCount).map { String(format: "f_%02d", $0) }

    static func countCell(_ index: Int) -> String {
        countCells[index]
    }

    static func valueCell(_ index: Int) -> String {
        valueCells[index]
    }

    static func squareCell(_ index: Int) -> String {
        valueCells[index + squareOffset]
    }

    func count(at index: Int) -> Int64 {
        self[Self.countCell(index)] as? Int64 ?? 0
    }

    func value(at index: Int) -> Double? {
        self[Self.valueCell(index)] as? Double
    }

    func square(at index: Int) -> Double? {
        self[Self.squareCell(index)] as? Double
    }

    func setCount(_ count: Int64, at index: Int) {
        self[Self.countCell(index)] = count
    }

    func setValue(_ value: Double?, at index: Int) {
        self[Self.valueCell(index)] = value
    }

    func setSquare(_ square: Double, at index: Int) {
        self[Self.squareCell(index)] = square
    }
}
