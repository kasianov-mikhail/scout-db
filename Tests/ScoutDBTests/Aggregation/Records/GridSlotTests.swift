//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("Grid slots")
struct GridSlotTests {
    @Test("The grid names one cell per hour of the week")
    func cellKeysCoverTheWeek() {
        #expect(GridSlot.cellKeys.count == 168)
        #expect(GridSlot.cellKeys.first == "c_000")
        #expect(GridSlot.cellKeys.last == "c_167")
        #expect(Set(GridSlot.cellKeys).count == GridSlot.cellKeys.count)
    }
}
