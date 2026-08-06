//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Testing

@testable import ScoutDB

@Suite("Integer vector deltas")
struct VectorDeltaTests {
    private func record() -> CKRecord {
        CKRecord(recordType: IntVector.recordType, recordID: CKRecord.ID(recordName: "int-vector-test"))
    }

    private func cell(_ record: CKRecord, at hour: Int) -> Int64? {
        record[IntVector.cellKeys[hour]] as? Int64
    }

    @Test("A cell opens at the delta and folds into what is already stored")
    func cellsFold() {
        let record = record()

        VectorDelta<IntVector>(kind: .sum, cells: [3: 2]).apply(to: record)
        #expect(cell(record, at: 3) == 2)

        VectorDelta<IntVector>(kind: .sum, cells: [3: 5]).apply(to: record)
        #expect(cell(record, at: 3) == 7)

        VectorDelta<IntVector>(kind: .max, cells: [3: 4]).apply(to: record)
        #expect(cell(record, at: 3) == 7)

        VectorDelta<IntVector>(kind: .min, cells: [3: 4]).apply(to: record)
        #expect(cell(record, at: 3) == 4)
    }

    @Test("A sum reverses cell by cell, an extreme has nothing to give back")
    func reversal() {
        let record = record()

        VectorDelta<IntVector>(kind: .sum, cells: [0: 9]).apply(to: record)
        VectorDelta<IntVector>(kind: .sum, cells: [0: 9]).reversed().apply(to: record)
        #expect(cell(record, at: 0) == 0)

        #expect(VectorDelta<IntVector>(kind: .max, cells: [0: 9]).reversed().cells.isEmpty)
    }

    @Test("A delta that moves nothing is a noop")
    func noop() {
        #expect(VectorDelta<IntVector>(kind: .sum, cells: [0: 0]).isNoop)
        #expect(!VectorDelta<IntVector>(kind: .sum, cells: [0: 1]).isNoop)
        #expect(VectorDelta<IntVector>(kind: .min).isNoop)
        #expect(!VectorDelta<IntVector>(kind: .min, cells: [0: 0]).isNoop)
    }
}
