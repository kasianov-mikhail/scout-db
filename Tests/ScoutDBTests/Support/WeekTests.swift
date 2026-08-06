//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Hours of the week")
struct WeekTests {
    @Test(
        "A date lands in the hour of the week it falls in, counted from Monday",
        arguments: [
            (36_000.0, 82),
            (1_785_937_500.0, 61),
            (1_785_715_200.0, 0),
            (1_786_319_999.0, 167),
            (-68_400.0, 53),
        ]
    )
    func hourOfADate(seconds: Double, hour: Int) {
        #expect(Date(timeIntervalSince1970: seconds).hourOfWeek == hour)
    }

    @Test("A week starts on the Monday before the date, at midnight UTC")
    func weekStartsOnMonday() {
        #expect(Date(timeIntervalSince1970: 36_000).weekStart == Date(timeIntervalSince1970: -259_200))
        #expect(Date(timeIntervalSince1970: 1_785_937_500).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
        #expect(Date(timeIntervalSince1970: 1_785_715_200).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
        #expect(Date(timeIntervalSince1970: 1_786_319_999).weekStart == Date(timeIntervalSince1970: 1_785_715_200))
    }
}
