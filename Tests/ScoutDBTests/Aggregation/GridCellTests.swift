//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Grid cells, addressed by day and hour")
struct GridCellTests {
    @Test(
        "A date lands in the cell of its UTC day and hour, counted from Monday",
        arguments: [
            (36_000.0, 3, 10),
            (1_785_937_500.0, 2, 13),
            (1_785_715_200.0, 0, 0),
            (1_786_319_999.0, 6, 23),
            (-68_400.0, 2, 5),
        ]
    )
    func cellOfADate(seconds: Double, day: Int, hour: Int) {
        let cell = GridCell(of: Date(timeIntervalSince1970: seconds))

        #expect(cell.day == day)
        #expect(cell.hour == hour)
    }

    @Test("A week starts on the Monday before the date, at midnight UTC")
    func weekStartsOnMonday() {
        #expect(Date(timeIntervalSince1970: 36_000).weekStart == Date(timeIntervalSince1970: -259_200))
        #expect(Date(timeIntervalSince1970: 1_785_937_500).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
        #expect(Date(timeIntervalSince1970: 1_785_715_200).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
        #expect(Date(timeIntervalSince1970: 1_786_319_999).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
    }

    @Test("The grid names one cell per hour of the week")
    func keysCoverTheWeek() {
        #expect(GridCell.keys.count == 168)
        #expect(GridCell.keys.first == "c_00_00")
        #expect(GridCell.keys.last == "c_06_23")
        #expect(Set(GridCell.keys).count == GridCell.keys.count)
    }
}
