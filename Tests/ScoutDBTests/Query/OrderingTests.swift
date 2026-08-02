//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Field order")
struct OrderingTests {
    @Test("A forward order ranks by the named field and leads with the records missing it")
    func forwardRanksMissingFirst() {
        let records = [note("n-1", rank: 2), note("n-2", rank: nil), note("n-3", rank: 1)]
        #expect(records.sorted(using: FieldOrder(key: .field("rank"))).map(\.uuid) == ["n-2", "n-3", "n-1"])
    }

    @Test("A reverse order flips the field along with the records missing it")
    func reverseFlipsMissingLast() {
        let records = [note("n-1", rank: 2), note("n-2", rank: nil), note("n-3", rank: 1)]
        let order = FieldOrder(key: .field("rank"), order: .reverse)
        #expect(records.sorted(using: order).map(\.uuid) == ["n-1", "n-3", "n-2"])
    }

    @Test("A trailing uuid order breaks ties the field leaves behind, whichever way the field runs")
    func uuidBreaksTies() {
        let records = [note("n-3", rank: 1), note("n-1", rank: 1), note("n-2", rank: 1)]
        let forward = [FieldOrder(key: .field("rank")), FieldOrder(key: .uuid)]
        let reverse = [FieldOrder(key: .field("rank"), order: .reverse), FieldOrder(key: .uuid)]
        #expect(records.sorted(using: forward).map(\.uuid) == ["n-1", "n-2", "n-3"])
        #expect(records.sorted(using: reverse).map(\.uuid) == ["n-1", "n-2", "n-3"])
    }

    @Test("Sort clauses carry their direction into the comparators they map to")
    func sortsMapToComparators() {
        let records = [
            note("n-1", rank: 1, group: "b"), note("n-2", rank: 2, group: "a"), note("n-3", rank: 1, group: "a"),
        ]
        let sorts = [EntityStore.Sort(field: "group"), EntityStore.Sort(field: "rank", order: .reverse)]
        #expect(records.sorted(using: sorts.map(FieldOrder.init)).map(\.uuid) == ["n-2", "n-3", "n-1"])
    }

    private func note(_ uuid: String, rank: Int64?, group: String? = nil) -> EntityRecord {
        var values: [String: RecordValue] = [:]
        values["rank"] = rank.map { .int($0) }
        values["group"] = group.map { .string($0) }
        return EntityRecord(entity: "note", uuid: uuid, schemaVersion: 1, values: values)
    }
}
