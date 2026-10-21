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

    private let counting = AggregateDefinition(group: "product", date: "date")
    private let spread = AggregateDefinition(group: "product", date: "date", parts: 8)
    private let products = (0..<64).map { "sku-\($0)" }

    private var offPart: String? {
        products.first { $0.bucket(count: spread.partCount) != 0 }
    }

    private let payment = makeDefinition(
        entity: "payment",
        version: 1,
        fields: [
            FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_02")),
            FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
            FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
        ]
    )

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

    private func page(week: Date?, part: Int) -> IndexPage {
        let index = VectorIndex(entity: "payment", aggregate: counting.name, week: week, part: part)

        let stored = database.records.first { $0.recordID == index.recordID }
        return stored?.indexPage ?? IndexPage(weeks: [], groups: [])
    }

    private var head: IndexPage {
        page(week: nil, part: 0)
    }

    private func groups(week: Date, parts: Int = 1) -> [String] {
        Set((0..<parts).flatMap { page(week: week, part: $0).groups }).sorted()
    }

    private func aggregator(_ slots: VectorCache = VectorCache()) -> VectorAggregator {
        aggregator(counting, slots: slots)
    }

    private func aggregator(_ aggregate: AggregateDefinition, slots: VectorCache = VectorCache()) -> VectorAggregator {
        VectorAggregator(database: database, aggregates: [aggregate], slots: slots)
    }

    @Test("A write names the week it lands in and the group it counts")
    func namesWhatItWrote() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app", "book"]))

        #expect(head.weeks == [noon.weekStart.millisecondsSince1970])
        #expect(groups(week: noon.weekStart) == ["app", "book"])
    }

    @Test("A second week joins the first rather than replacing it")
    func weeksAccumulate() async throws {
        let later = noon.addingTimeInterval(7 * 86_400)

        try await aggregator().rebalance(old: [], new: payments(["app"]))
        try await aggregator().rebalance(old: [], new: payments(["app"], at: later))

        #expect(
            head.weeks == [
                noon.weekStart.millisecondsSince1970, later.weekStart.millisecondsSince1970,
            ]
        )
        #expect(groups(week: later.weekStart) == ["app"])
    }

    @Test("A group already named is not written twice")
    func groupsStayDistinct() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app"]))
        database.resetRequests()

        try await aggregator().rebalance(old: [], new: payments(["app"]))

        #expect(groups(week: noon.weekStart) == ["app"])
        #expect(database.requests[.conditionalSave] == 1)
    }

    @Test("A vector written by an earlier run is named without being rewritten")
    func coldSlotIsNamedAgain() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app"]))

        for record in database.records where record.recordID.recordName.hasPrefix("index-") {
            try await database.modifyRecords(saving: [], deleting: [record.recordID])
        }

        try await aggregator().rebalance(old: [], new: payments(["app"]))

        #expect(head.weeks == [noon.weekStart.millisecondsSince1970])
        #expect(groups(week: noon.weekStart) == ["app"])
    }

    @Test("A failed index write leaves no vector behind")
    func indexPrecedesTheVector() async throws {
        database.writeErrors = [CKError(.networkFailure)]

        await #expect(throws: (any Error).self) {
            try await aggregator().rebalance(old: [], new: payments(["app"]))
        }

        #expect(database.records.filter { $0.recordType == VectorSlot.recordType }.isEmpty)
    }

    @Test("A page that does not decode is refused rather than read as empty")
    func malformedPageIsRefused() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app"]))

        let head = VectorIndex(entity: "payment", aggregate: counting.name)
        let record = try #require(database.records.first { $0.recordID == head.recordID })
        record[IndexPage.key] = Data([0x7b, 0x00])

        await #expect(throws: SchemaError.malformedRecord(head.recordID.recordName)) {
            try await VectorReader(database: database, definition: payment, aggregate: counting)
                .rows(groups: nil)
        }
        await #expect(throws: SchemaError.malformedRecord(head.recordID.recordName)) {
            try await VectorIndexWriter(database: database).write(
                wanted: [
                    VectorSlot(
                        entity: "payment",
                        aggregate: counting.name,
                        group: "book",
                        shard: nil,
                        part: 0,
                        week: noon.weekStart
                    )
                ]
                .indexPages
            )
        }
    }

    @Test("A read of an aggregate nothing has written leaves the head behind for the next one")
    func readSeedsTheMissingHead() async throws {
        let head = VectorIndex(entity: "payment", aggregate: counting.name)

        let rows = try await VectorReader(database: database, definition: payment, aggregate: counting)
            .rows(groups: nil)

        #expect(rows.isEmpty)

        let record = try #require(database.records.first { $0.recordID == head.recordID })
        #expect(record.indexPage == IndexPage(weeks: [], groups: []))

        database.resetRequests()
        _ = try await VectorReader(database: database, definition: payment, aggregate: counting).rows(groups: nil)

        #expect(database.requests[.conditionalSave] == 0, "A head that stands is read, not written again")
    }

    @Test("A read leaves the head a write already named as it is")
    func readKeepsTheStandingHead() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app"]))

        _ = try await VectorReader(database: database, definition: payment, aggregate: counting).rows(groups: nil)

        #expect(head.weeks == [noon.weekStart.millisecondsSince1970])
        #expect(groups(week: noon.weekStart) == ["app"])
    }

    @Test("A fold reads every group the index names")
    func foldSeesEveryGroup() async throws {
        try await aggregator().rebalance(old: [], new: payments(["app", "book", "toy"]))

        let rows = try await VectorReader(database: database, definition: payment, aggregate: counting)
            .rows(groups: nil)
            .vectorRows(kind: .sum)

        #expect(rows.keys.sorted() == ["app", "book", "toy"])
        #expect(rows.values.reduce(0, +) == 3)
    }

    @Test("An aggregate without parts keeps one page per week")
    func unsplitAggregateWritesOnePage() async throws {
        try await aggregator().rebalance(old: [], new: payments(products))

        #expect(page(week: noon.weekStart, part: 0).groups == products.sorted())
        #expect((1..<8).allSatisfy { page(week: noon.weekStart, part: $0).groups.isEmpty })
    }

    @Test("A week's groups spread over the aggregate's parts by name")
    func groupsSpreadOverParts() async throws {
        try await aggregator(spread).rebalance(old: [], new: payments(products))

        let pages = (0..<spread.partCount).map { page(week: noon.weekStart, part: $0).groups }

        #expect(pages.filter { !$0.isEmpty }.count > 1)
        for (part, named) in pages.enumerated() {
            #expect(named.allSatisfy { $0.bucket(count: spread.partCount) == part })
        }
        #expect(groups(week: noon.weekStart, parts: spread.partCount) == products.sorted())
    }

    @Test("Raising the parts keeps the page written before them readable")
    func unsplitPageIsRead() async throws {
        let product = try #require(offPart)

        try await aggregator().rebalance(old: [], new: payments([product]))

        let rows = try await VectorReader(database: database, definition: payment, aggregate: spread)
            .rows(groups: nil)
            .vectorRows(kind: .sum)

        #expect(rows == [product: 1])
    }

    @Test("A group named in the old page and in its part is counted once")
    func overlappingPagesCountOnce() async throws {
        let product = try #require(offPart)

        try await aggregator().rebalance(old: [], new: payments([product]))
        try await aggregator(spread).rebalance(old: [], new: payments([product]))

        #expect(page(week: noon.weekStart, part: 0).groups == [product])
        #expect(page(week: noon.weekStart, part: product.bucket(count: spread.partCount)).groups == [product])

        let rows = try await VectorReader(database: database, definition: payment, aggregate: spread)
            .rows(groups: nil)
            .vectorRows(kind: .sum)

        #expect(rows == [product: 2])
    }

    @Test("The first part keeps the name the week page had before the parts")
    func firstPartKeepsItsName() {
        let week = noon.weekStart
        let index = VectorIndex(entity: "payment", aggregate: counting.name, week: week, part: 0)
        let components = ["payment", counting.name, String(week.millisecondsSince1970)]

        #expect(index.recordID.recordName == "index-" + contentDigest(components: components))
    }
}
