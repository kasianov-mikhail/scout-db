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
        database.records.filter { $0.recordType == VectorSlot.recordType }
    }

    @Test("Every slot a batch touches is read and written in one request each, and the index in one more")
    func batchedSlots() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [
                AggregateDefinition(group: "product", date: "date"),
                AggregateDefinition(metric: .sum, field: "amount", group: "product", date: "date"),
            ],
            slots: VectorCache()
        )

        try await aggregator.rebalance(removing: [], adding: payments(["app", "pro", "max"]))

        #expect(slots.count == 6)
        #expect(requests(.fetch) == 3)
        #expect(requests(.conditionalSave) == 2)
        #expect(requests(.query) == 0)
    }

    @Test("A slot and a head index read before stay cached, so the next write only saves")
    func warmSlotSkipsTheFetch() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(metric: .sum, field: "amount", date: "date")],
            slots: VectorCache()
        )
        try await aggregator.rebalance(removing: [], adding: payments(["app"]))
        try await aggregator.rebalance(removing: [], adding: payments(["pro"]))
        database.resetRequests()

        try await aggregator.rebalance(removing: [], adding: payments(["max"]))

        #expect(requests(.fetch) == 0)
        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 3)
    }

    @Test("The head index is read once for the shard counts, and served from the cache after")
    func headIndexIsReadOnce() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(metric: .sum, field: "amount", date: "date")],
            slots: VectorCache()
        )
        try await aggregator.rebalance(removing: [], adding: payments(["app"]))
        try await aggregator.rebalance(removing: [], adding: payments(["pro"]))
        database.resetRequests()

        for product in ["max", "ultra", "mini"] {
            try await aggregator.rebalance(removing: [], adding: payments([product]))
        }

        #expect(requests(.fetch) == 0)
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
        let aggregates = [AggregateDefinition(metric: .min, field: "amount", date: "date")]
        let stored = payment(amount: 5)
        try await VectorAggregator(database: database, aggregates: aggregates, slots: VectorCache())
            .rebalance(removing: [], adding: [stored])
        database.resetRequests()

        try await VectorAggregator(database: database, aggregates: aggregates, slots: VectorCache())
            .rebalance(removing: [stored], adding: [payment(amount: 9)])

        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 5)
    }

    @Test("An update that lowers a min aggregate's value still writes the slot")
    func loweredMinWritesTheSlot() async throws {
        let aggregates = [AggregateDefinition(metric: .min, field: "amount", date: "date")]
        let stored = payment(amount: 5)
        try await VectorAggregator(database: database, aggregates: aggregates, slots: VectorCache())
            .rebalance(removing: [], adding: [stored])
        database.resetRequests()

        try await VectorAggregator(database: database, aggregates: aggregates, slots: VectorCache())
            .rebalance(removing: [stored], adding: [payment(amount: 2)])

        #expect(requests(.conditionalSave) == 1)
        #expect(try #require(slots.first)[cell: hour] == 2)
    }

    @Test("A slot another writer moved on is folded again over the server copy")
    func staleSlotRetriesOverTheServerCopy() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(metric: .sum, field: "amount", date: "date")],
            slots: VectorCache()
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

    @Test("A slot that loses four races in a row still lands, folded once over the copy it last lost to")
    func repeatedConflictsStillLand() async throws {
        let aggregator = VectorAggregator(
            database: database,
            aggregates: [AggregateDefinition(metric: .sum, field: "amount", date: "date")],
            slots: VectorCache()
        )
        try await aggregator.rebalance(removing: [], adding: [payment(amount: 1)])

        let slot = try #require(slots.first)
        database.writeErrors = (0..<4).map { _ in
            let server = slot.duplicate()
            server[cell: hour] = 10
            return RecordConflictError(serverRecord: server)
        }
        database.resetRequests()

        try await aggregator.rebalance(removing: [], adding: [payment(amount: 3)])

        #expect(requests(.conditionalSave) == 6)
        #expect(try #require(slots.first)[cell: hour] == 13)
    }

    private func aggregator(_ aggregate: AggregateDefinition, slots cache: VectorCache) -> VectorAggregator {
        VectorAggregator(database: database, aggregates: [aggregate], slots: cache)
    }

    private func headShards(_ aggregate: String) throws -> [String: Int] {
        let head = VectorIndex(entity: "payment", aggregate: aggregate, week: nil)
        let record = database.records.first { $0.recordID == head.recordID }

        return try #require(record?.indexPage).shards
    }

    private func contend(_ aggregator: VectorAggregator, losing races: Int) async throws {
        let slot = try #require(slots.first)

        database.writeErrors = (0..<races).map { _ in
            let server = slot.duplicate()
            server[cell: hour] = 10
            return RecordConflictError(serverRecord: server)
        }
        try await aggregator.rebalance(removing: [], adding: [payment(amount: 3)])
    }

    @Test("A week whose slot keeps losing races doubles, and the writer spreads over it next time")
    func contentionDoublesTheWeek() async throws {
        let cache = VectorCache()
        let aggregator = aggregator(AggregateDefinition(metric: .sum, field: "amount", date: "date"), slots: cache)

        try await aggregator.rebalance(removing: [], adding: [payment(amount: 1)])
        try await contend(aggregator, losing: 3)

        #expect(try headShards("sum_amount_at_date") == [String(noon.weekStart.millisecondsSince1970): 2])
        #expect(slots.count == 1)

        try await aggregator.rebalance(removing: [], adding: [payment(amount: 7)])

        #expect(slots.count == 2)
    }

    @Test("Losing fewer races than the threshold leaves the week where it was")
    func briefContentionDoesNotSpread() async throws {
        let cache = VectorCache()
        let aggregator = aggregator(AggregateDefinition(metric: .sum, field: "amount", date: "date"), slots: cache)

        try await aggregator.rebalance(removing: [], adding: [payment(amount: 1)])
        try await contend(aggregator, losing: 2)

        #expect(try headShards("sum_amount_at_date").isEmpty)
        #expect(slots.count == 1)
    }
}
