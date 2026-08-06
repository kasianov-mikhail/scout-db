//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("The index that names the vectors")
struct VectorIndexTests {
    let database = InMemoryDatabase()
    let noon = Date(timeIntervalSince1970: 36_000)

    private let counting = AggregateDefinition(groupBy: "product", date: "date")

    private func payments(_ products: [String], at date: Date? = nil) -> [EntityRecord] {
        products.enumerated().map { index, product in
            EntityRecord(
                entity: "payment",
                uuid: "p-\(index)",
                schemaVersion: 1,
                values: ["product": .string(product), "amount": .double(1), "date": .date(date ?? noon)]
            )
        }
    }

    private func page(week: Date?) throws -> VectorIndex.Page {
        let index = VectorIndex(entity: "payment", aggregate: counting.name, week: week)

        guard let record = database.records.first(where: { $0.recordID == index.recordID }) else {
            return VectorIndex.Page()
        }
        return try VectorIndex.page(of: record)
    }

    private func aggregator(_ slots: VectorCache = VectorCache()) -> VectorAggregator {
        VectorAggregator(database: database, aggregates: [counting], slots: slots)
    }

    @Test("A write names the week it lands in and the group it counts")
    func namesWhatItWrote() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app", "book"]))

        #expect(try page(week: nil).weeks == [noon.weekStart.millisecondsSince1970])
        #expect(try page(week: noon.weekStart).groups == ["app", "book"])
    }

    @Test("A second week joins the first rather than replacing it")
    func weeksAccumulate() async throws {
        let later = noon.addingTimeInterval(7 * 86_400)

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))
        try await aggregator().rebalance(removing: [], adding: payments(["app"], at: later))

        #expect(
            try page(week: nil).weeks == [
                noon.weekStart.millisecondsSince1970, later.weekStart.millisecondsSince1970,
            ]
        )
        #expect(try page(week: later.weekStart).groups == ["app"])
    }

    @Test("A group already named is not written twice")
    func groupsStayDistinct() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app"]))
        database.resetRequests()

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        #expect(try page(week: noon.weekStart).groups == ["app"])
        #expect(database.requests[.conditionalSave] == 1)
    }

    @Test("A vector written by an earlier run is named without being rewritten")
    func coldSlotIsNamedAgain() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        for record in database.records where record.recordID.recordName.hasPrefix("index-") {
            try await database.modifyRecords(saving: [], deleting: [record.recordID])
        }

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        #expect(try page(week: nil).weeks == [noon.weekStart.millisecondsSince1970])
        #expect(try page(week: noon.weekStart).groups == ["app"])
    }

    @Test("A fold reads every group the index names")
    func foldSeesEveryGroup() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app", "book", "toy"]))

        let rows = try await VectorReader(database: database, entity: "payment", aggregate: counting)
            .rows()
            .vectorRows(folding: .sum)

        #expect(rows.keys.sorted() == ["app", "book", "toy"])
        #expect(rows.values.reduce(0, +) == 3)
    }
}
