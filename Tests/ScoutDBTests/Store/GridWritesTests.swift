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
    let backing = InMemoryDatabase()
    let recorder = Recorder()
    let database: ObservedDatabase
    let noon = Date(timeIntervalSince1970: 36_000)

    init() {
        database = ObservedDatabase(backing: backing, observer: recorder)
    }

    private func paymentDefinition(views: [AggregateView]) -> EntityDefinition {
        makeDefinition(
            entity: "payment",
            fields: [
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
            ], envelopeDate: "date", views: views)
    }

    private func payments(_ products: [String]) -> [EntityRecord] {
        products.enumerated().map { index, product in
            EntityRecord(
                entity: "payment", uuid: "p-\(index)", schemaVersion: 2,
                values: ["product": .string(product), "amount": .double(1), "date": .date(noon)])
        }
    }

    private func requests(_ kind: DatabaseOperation.Kind) -> Int {
        recorder.operations.filter { $0.kind == kind }.count
    }

    private var slots: [CKRecord] {
        backing.records.filter { $0.recordType == Aggregate.recordType }
    }

    @Test("Every slot a batch touches is read and written in one request each")
    func batchedSlots() async throws {
        let definition = paymentDefinition(views: [
            AggregateView(name: "daily", groupBy: "product", bucket: .day),
            AggregateView(name: "revenue", groupBy: "product", bucket: .lifetime, sum: "amount"),
        ])
        let aggregator = GridAggregator(database: database)

        try await aggregator.record(payments(["app", "pro", "max"]), using: definition)

        #expect(slots.count == 6)
        #expect(requests(.fetch) == 1)
        #expect(requests(.conditionalSave) == 1)
        #expect(requests(.query) == 0)
    }

    @Test("A slot written before stays cached, so the next write only saves")
    func warmSlotSkipsTheFetch() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", bucket: .lifetime, sum: "amount")])
        let aggregator = GridAggregator(database: database)
        try await aggregator.record(payments(["app"]), using: definition)
        recorder.reset()

        try await aggregator.record(payments(["pro"]), using: definition)

        #expect(requests(.fetch) == 0)
        #expect(requests(.conditionalSave) == 1)
        let slot = try #require(slots.first)
        #expect(slot["c_00"] as? Int64 == 2)
        #expect(slot["f_00"] as? Double == 2)
    }

    @Test("Only a slot named before separators were escaped falls back to a query")
    func fallbackIsScopedToRenamedSlots() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "daily", groupBy: "product", bucket: .day)])
        let aggregator = GridAggregator(database: database)

        try await aggregator.record(payments(["app"]), using: definition)
        #expect(requests(.query) == 0)

        recorder.reset()
        try await aggregator.record(payments(["a|b"]), using: definition)
        #expect(requests(.query) == 1)
    }

    @Test("A slot another writer moved on is folded again over the server copy")
    func staleSlotRetriesOverTheServerCopy() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", bucket: .lifetime, sum: "amount")])
        let aggregator = GridAggregator(database: database)
        try await aggregator.record(payments(["app"]), using: definition)

        let server = try #require(slots.first).copy() as! CKRecord
        server["c_00"] = (server["c_00"] as? Int64 ?? 0) + 5
        try await backing.modifyRecords(saving: [server], deleting: [])
        recorder.reset()

        try await aggregator.record(payments(["pro"]), using: definition)

        #expect(requests(.conditionalSave) == 2)
        let slot = try #require(slots.first)
        #expect(slot["c_00"] as? Int64 == 7)
    }

    @Test("A slot written offline joins the queue instead of failing the write")
    func offlineSlotIsQueued() async throws {
        let cache = OfflineCache(backing: backing)
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", bucket: .lifetime, sum: "amount")])
        backing.writeErrors = [CKError(.networkUnavailable), CKError(.networkUnavailable)]

        try await GridAggregator(database: cache).record(payments(["app"]), using: definition)

        #expect(slots.isEmpty)
        #expect(cache.pendingWrites == 1)
    }

    @Test("A cached slot deleted on the server is written again from scratch")
    func vanishedSlotIsRebuilt() async throws {
        let definition = paymentDefinition(views: [AggregateView(name: "revenue", bucket: .lifetime, sum: "amount")])
        let aggregator = GridAggregator(database: database)
        try await aggregator.record(payments(["app"]), using: definition)

        backing.records.removeAll { $0.recordType == Aggregate.recordType }
        backing.writeErrors = [CKError(.unknownItem)]

        try await aggregator.record(payments(["pro"]), using: definition)

        let slot = try #require(slots.first)
        #expect(slot["c_00"] as? Int64 == 1)
    }
}
