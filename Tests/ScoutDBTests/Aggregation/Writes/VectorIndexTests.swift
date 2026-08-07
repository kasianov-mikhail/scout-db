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

    private func page(week: Date?) -> VectorIndex.Page {
        let index = VectorIndex(slug: IntVector.slug, entity: "payment", aggregate: counting.name, week: week)

        return database.records.first { $0.recordID == index.recordID }?.indexPage ?? VectorIndex.Page()
    }

    private func aggregator(_ slots: VectorCache = VectorCache()) -> VectorAggregator {
        VectorAggregator(database: database, aggregates: [counting], slots: slots)
    }

    @Test("A write names the week it lands in and the group it counts")
    func namesWhatItWrote() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app", "book"]))

        #expect(page(week: nil).weeks == [noon.weekStart.millisecondsSince1970])
        #expect(page(week: noon.weekStart).groups == ["app", "book"])
    }

    @Test("A second week joins the first rather than replacing it")
    func weeksAccumulate() async throws {
        let later = noon.addingTimeInterval(7 * 86_400)

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))
        try await aggregator().rebalance(removing: [], adding: payments(["app"], at: later))

        #expect(
            page(week: nil).weeks == [
                noon.weekStart.millisecondsSince1970, later.weekStart.millisecondsSince1970,
            ]
        )
        #expect(page(week: later.weekStart).groups == ["app"])
    }

    @Test("A group already named is not written twice")
    func groupsStayDistinct() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app"]))
        database.resetRequests()

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        #expect(page(week: noon.weekStart).groups == ["app"])
        #expect(database.requests[.conditionalSave] == 1)
    }

    @Test("A vector written by an earlier run is named without being rewritten")
    func coldSlotIsNamedAgain() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        for record in database.records where record.recordID.recordName.hasPrefix("\(IntVector.slug)-index-") {
            try await database.modifyRecords(saving: [], deleting: [record.recordID])
        }

        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        #expect(page(week: nil).weeks == [noon.weekStart.millisecondsSince1970])
        #expect(page(week: noon.weekStart).groups == ["app"])
    }

    @Test("A failed index write leaves no vector behind")
    func indexPrecedesTheVector() async throws {
        database.writeErrors = [CKError(.networkFailure)]

        await #expect(throws: (any Error).self) {
            try await aggregator().rebalance(removing: [], adding: payments(["app"]))
        }

        #expect(database.records.filter { $0.recordType == IntVector.recordType }.isEmpty)
    }

    @Test("A page that does not decode is refused rather than read as empty")
    func malformedPageIsRefused() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app"]))

        let head = VectorIndex(slug: IntVector.slug, entity: "payment", aggregate: counting.name, week: nil)
        let record = try #require(database.records.first { $0.recordID == head.recordID })
        record[VectorIndex.pageKey] = Data([0x7b, 0x00])

        await #expect(throws: SchemaError.malformedRecord(head.recordID.recordName)) {
            try await VectorReader<IntVector>(database: database, entity: "payment", aggregate: counting)
                .rows(groups: nil)
        }
        await #expect(throws: SchemaError.malformedRecord(head.recordID.recordName)) {
            try await VectorIndexWriter(database: database).note([
                VectorSlot<IntVector>(
                    entity: "payment",
                    aggregate: counting.name,
                    group: "book",
                    shard: nil,
                    week: noon.weekStart
                )
            ])
        }
    }

    @Test("A fold reads every group the index names")
    func foldSeesEveryGroup() async throws {
        try await aggregator().rebalance(removing: [], adding: payments(["app", "book", "toy"]))

        let rows = try await VectorReader<IntVector>(database: database, entity: "payment", aggregate: counting)
            .rows(groups: nil)
            .vectorRows(of: IntVector.self, folding: .sum, where: nil)

        #expect(rows.keys.sorted() == ["app", "book", "toy"])
        #expect(rows.values.reduce(0, +) == 3)
    }
}
