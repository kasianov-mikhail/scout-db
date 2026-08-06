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

@Suite("Vector writes")
struct VectorWritesTests {
    let database = InMemoryDatabase()
    let noon = Date(timeIntervalSince1970: 36_000)

    private func payments(_ products: [String]) -> [EntityRecord] {
        products.enumerated().map { index, product in
            EntityRecord(
                entity: "payment",
                uuid: "p-\(index)",
                schemaVersion: 2,
                values: ["product": .string(product), "amount": .double(1), "date": .date(noon)]
            )
        }
    }

    private var hour: Int {
        noon.hourOfWeek
    }

    private func requests(_ kind: RequestTally.Kind) -> Int {
        database.requests[kind]
    }

    private var slots: [CKRecord] {
        database.records.filter { $0.recordType == DoubleVector.recordType }
    }

    @Test("Every slot a batch touches is read and written in one request each, and the index in one more")
    func batchedSlots() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [
                AggregateDefinition(groupBy: "product", date: "date"),
                AggregateDefinition(groupBy: "product", measure: .sum("amount"), date: "date"),
            ]
        )

        try await aggregator.rebalance(removing: [], adding: payments(["app", "pro", "max"]))

        #expect(slots.count == 6)
        #expect(requests(.fetch) == 2)
        #expect(requests(.conditionalSave) == 2)
        #expect(requests(.query) == 0)
    }

    @Test("A slot written before stays cached, so the next write only saves")
    func warmSlotSkipsTheFetch() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(measure: .sum("amount"), date: "date")]
        )
        try await aggregator.rebalance(removing: [], adding: payments(["app"]))
        database.resetRequests()

        try await aggregator.rebalance(removing: [], adding: payments(["pro"]))

        #expect(requests(.fetch) == 0)
        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 2)
    }

    private func payment(amount: Double) -> EntityRecord {
        EntityRecord(
            entity: "payment",
            uuid: "p-0",
            schemaVersion: 2,
            values: ["product": .string("app"), "amount": .double(amount), "date": .date(noon)]
        )
    }

    @Test("An update that raises a min aggregate's value leaves the value standing")
    func raisedMinLeavesTheValue() async throws {
        let aggregates = [AggregateDefinition(measure: .min("amount"), date: "date")]
        let stored = payment(amount: 5)
        try await VectorAggregator(database: database, aggregates: aggregates)
            .rebalance(removing: [], adding: [stored])
        database.resetRequests()

        try await VectorAggregator(database: database, aggregates: aggregates)
            .rebalance(removing: [stored], adding: [payment(amount: 9)])

        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 5)
    }

    @Test("An update that lowers a min aggregate's value still writes the slot")
    func loweredMinWritesTheSlot() async throws {
        let aggregates = [AggregateDefinition(measure: .min("amount"), date: "date")]
        let stored = payment(amount: 5)
        try await VectorAggregator(database: database, aggregates: aggregates)
            .rebalance(removing: [], adding: [stored])
        database.resetRequests()

        try await VectorAggregator(database: database, aggregates: aggregates)
            .rebalance(removing: [stored], adding: [payment(amount: 2)])

        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 2)
    }

    @Test("A slot another writer moved on is folded again over the server copy")
    func staleSlotRetriesOverTheServerCopy() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(measure: .sum("amount"), date: "date")]
        )
        try await aggregator.rebalance(removing: [], adding: payments(["app"]))

        let server = try #require(slots.first).copy() as! CKRecord
        server[cell: hour] = (server[cell: hour] ?? 0) + 5
        try await database.modifyRecords(saving: [server], deleting: [])
        database.resetRequests()

        try await aggregator.rebalance(removing: [], adding: payments(["pro"]))

        #expect(requests(.conditionalSave) == 2)
        #expect(try #require(slots.first)[cell: hour] == 7)
    }
}
