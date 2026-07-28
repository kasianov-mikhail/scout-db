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

@Suite("Live query coalescing")
struct LiveQueryCoalescingTests {
    @Test("Writes landing during a pass fold into one trailing result, with no second query")
    func burstCoalesces() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let gated = GatedQueryDatabase(backing: database)
        let store = EntityStore(database: gated, registry: registry)

        let seen = Seen()
        let stream = store.query("purchase").observe()
        let consumer = Task {
            for try await records in stream {
                await seen.record(records.map(\.uuid))
            }
        }
        defer { consumer.cancel() }

        await gated.gate.awaitArrival()
        for index in 0..<10 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }
        await gated.gate.open()

        try await poll { await seen.passes == 2 }
        #expect(await seen.latest?.count == 10)

        try await Task.sleep(for: .milliseconds(50))
        #expect(await seen.passes == 2)
        #expect(await gated.gate.calls == 1)
    }

    @Test("A live query folds a landed write in and re-reads only what it cannot")
    func splicesKnownChanges() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let gated = GatedQueryDatabase(backing: database)
        let store = EntityStore(database: gated, registry: registry)
        await gated.gate.open()

        var values = makePurchase().values
        values["product_id"] = .string("sku-42")
        try await store.write(values, entity: "purchase", uuid: "p-1")

        let seen = Seen()
        let stream = store.query("purchase").filter("product_id", .equals, "sku-42").observe()
        let consumer = Task {
            for try await records in stream {
                await seen.record(records.map(\.uuid))
            }
        }
        defer { consumer.cancel() }
        try await poll { await seen.passes == 1 }
        #expect(await seen.latest == ["p-1"])
        let opening = await gated.gate.calls

        try await store.write(values, entity: "purchase", uuid: "p-2")
        try await poll { await seen.latest == ["p-1", "p-2"] }

        var other = values
        other["product_id"] = .string("sku-9")
        try await store.write(other, entity: "purchase", uuid: "p-3")
        try await store.delete(entity: "purchase", uuid: "p-1")
        try await poll { await seen.latest == ["p-2"] }
        #expect(await gated.gate.calls == opening)
    }

    @Test("Every raw tick survives a slow consumer")
    func rawTicksKeepEveryMutation() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let store = EntityStore(database: database, registry: registry)

        let ticks = store.changeTicks(entity: "purchase")
        for index in 0..<3 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }

        var counted = 0
        for await _ in ticks {
            counted += 1
            if counted == 3 { break }
        }
        #expect(counted == 3)
    }

    private func poll(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition never held")
    }
}

private actor Seen {
    private(set) var passes = 0
    private(set) var latest: [String]?

    func record(_ uuids: [String]) {
        passes += 1
        latest = uuids
    }
}

private actor QueryGate {
    private(set) var calls = 0
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        calls += 1
        arrivals.forEach { $0.resume() }
        arrivals = []
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func open() {
        isOpen = true
        parked.forEach { $0.resume() }
        parked = []
    }

    func awaitArrival() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}

private final class GatedQueryDatabase: CloudDatabase, @unchecked Sendable {
    let backing: InMemoryDatabase
    let gate = QueryGate()

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if query.recordType == Entity.recordType {
            await gate.pass()
        }
        return try await backing.records(matching: query, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await backing.save(record)
    }

    func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await backing.modifyRecords(saving: records, deleting: recordIDs)
    }

    func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await backing.saveIfUnchanged(records)
    }

    func save(subscription: CKSubscription) async throws {
        try await backing.save(subscription: subscription)
    }

    func deleteSubscription(id: CKSubscription.ID) async throws {
        try await backing.deleteSubscription(id: id)
    }

    func subscriptions() async throws -> [CKSubscription] {
        try await backing.subscriptions()
    }

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await backing.fetchRecord(id: id)
    }
}
