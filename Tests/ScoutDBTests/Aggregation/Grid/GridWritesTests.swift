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

@Suite("Grid writes")
struct GridWritesTests {
    let database = InMemoryDatabase()
    let noon = Date(timeIntervalSince1970: 36_000)

    private func paymentDefinition(views: [AggregateView]) -> EntityDefinition {
        makeDefinition(
            entity: "payment",
            fields: [
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ],
            views: views
        )
    }

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

    private func requests(_ kind: RequestTally.Kind) -> Int {
        database.requests[kind]
    }

    private var slots: [CKRecord] {
        database.records.filter { $0.recordType == GridSlot.recordType }
    }

    @Test("Every slot a batch touches is read and written in one request each")
    func batchedSlots() async throws {
        let definition = paymentDefinition(views: [
            AggregateView(name: "by_product", groupBy: "product"),
            AggregateView(name: "revenue", groupBy: "product", sum: "amount"),
        ]
        )
        let aggregator = GridAggregator(database: database)

        try await aggregator.record(payments(["app", "pro", "max"]), using: definition)

        #expect(slots.count == 6)
        #expect(requests(.fetch) == 1)
        #expect(requests(.conditionalSave) == 1)
        #expect(requests(.query) == 0)
    }

    @Test("A slot written before stays cached, so the next write only saves")
    func warmSlotSkipsTheFetch() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", sum: "amount")])
        let aggregator = GridAggregator(database: database)
        try await aggregator.record(payments(["app"]), using: definition)
        database.resetRequests()

        try await aggregator.record(payments(["pro"]), using: definition)

        #expect(requests(.fetch) == 0)
        #expect(requests(.conditionalSave) == 1)
        let slot = try #require(slots.first)
        #expect(slot["c_00"] as? Int64 == 2)
        #expect(slot["f_00"] as? Double == 2)
    }

    @Test("Only a slot named before separators were escaped falls back to a query")
    func fallbackIsScopedToRenamedSlots() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "by_product", groupBy: "product")])
        let aggregator = GridAggregator(database: database)

        try await aggregator.record(payments(["app"]), using: definition)
        #expect(requests(.query) == 0)

        database.resetRequests()
        try await aggregator.record(payments(["a|b"]), using: definition)
        #expect(requests(.query) == 1)
    }

    private func payment(amount: Double) -> EntityRecord {
        EntityRecord(
            entity: "payment",
            uuid: "p-0",
            schemaVersion: 2,
            values: ["product": .string("app"), "amount": .double(amount), "date": .date(noon)]
        )
    }

    @Test("An update that leaves a min view's value where it stands touches no slot")
    func unchangedMinSkipsTheSlot() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "cheapest", min: "amount")])
        let stored = payment(amount: 5)
        try await GridAggregator(database: database).record([stored], using: definition)
        database.resetRequests()

        try await GridAggregator(database: database).rebalance(
            removing: [stored],
            adding: [payment(amount: 9)],
            using: definition
        )

        #expect(requests(.fetch) == 0)
        #expect(requests(.conditionalSave) == 0)
        #expect(try #require(slots.first)["f_00"] as? Double == 5)
    }

    @Test("An update that lowers a min view's value still writes the slot")
    func loweredMinWritesTheSlot() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "cheapest", min: "amount")])
        let stored = payment(amount: 5)
        try await GridAggregator(database: database).record([stored], using: definition)
        database.resetRequests()

        try await GridAggregator(database: database).rebalance(
            removing: [stored],
            adding: [payment(amount: 2)],
            using: definition
        )

        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)["f_00"] as? Double == 2)
    }

    @Test("A slot another writer moved on is folded again over the server copy")
    func staleSlotRetriesOverTheServerCopy() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", sum: "amount")])
        let aggregator = GridAggregator(database: database)
        try await aggregator.record(payments(["app"]), using: definition)

        let server = try #require(slots.first).copy() as! CKRecord
        server["c_00"] = (server["c_00"] as? Int64 ?? 0) + 5
        try await database.modifyRecords(saving: [server], deleting: [])
        database.resetRequests()

        try await aggregator.record(payments(["pro"]), using: definition)

        #expect(requests(.conditionalSave) == 2)
        let slot = try #require(slots.first)
        #expect(slot["c_00"] as? Int64 == 7)
    }
}
