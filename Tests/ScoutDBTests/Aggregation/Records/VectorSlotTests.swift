//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("Vector slots")
struct VectorSlotTests {
    @Test("A vector names one cell per hour of the week")
    func cellKeysCoverTheWeek() {
        #expect(VectorSlot.cellKeys.count == 168)
        #expect(VectorSlot.cellKeys.first == "c_000")
        #expect(VectorSlot.cellKeys.last == "c_167")
        #expect(Set(VectorSlot.cellKeys).count == VectorSlot.cellKeys.count)
    }
}
