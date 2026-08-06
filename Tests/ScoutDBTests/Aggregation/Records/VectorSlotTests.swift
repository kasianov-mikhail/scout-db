//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Vector slots")
struct VectorSlotTests {
    private let week = Date(timeIntervalSince1970: 1_700_000_000).weekStart

    private func slot<Holder: Vector>(_ holder: Holder.Type) -> VectorSlot<Holder> {
        VectorSlot(entity: "payment", aggregate: "by_all", group: "", shard: nil, week: week)
    }

    @Test("A vector names one cell per hour of the week")
    func cellKeysCoverTheWeek() {
        #expect(DoubleVector.cellKeys.count == 168)
        #expect(DoubleVector.cellKeys.first == "c_000")
        #expect(DoubleVector.cellKeys.last == "c_167")
        #expect(Set(DoubleVector.cellKeys).count == DoubleVector.cellKeys.count)
    }

    @Test("Both holders address the week by the same cells")
    func holdersShareTheCellKeys() {
        #expect(IntVector.cellKeys == DoubleVector.cellKeys)
    }

    @Test("The same coordinates name a different record in each holder")
    func holdersNameApart() {
        let double = slot(DoubleVector.self)
        let int = slot(IntVector.self)

        #expect(double.recordID != int.recordID)
        #expect(double.recordID.recordName.hasPrefix("double-vector-"))
        #expect(int.recordID.recordName.hasPrefix("int-vector-"))
        #expect(DoubleVector.recordType != IntVector.recordType)
    }

    @Test("An index page is filed per holder")
    func indexNamesApart() {
        let double = slot(DoubleVector.self).index
        let int = slot(IntVector.self).index

        #expect(double.head.recordID != int.head.recordID)
        #expect(double.week.recordID != int.week.recordID)
        #expect(double.head.recordID.recordName.hasPrefix("double-index-"))
        #expect(int.head.recordID.recordName.hasPrefix("int-index-"))
    }
}
