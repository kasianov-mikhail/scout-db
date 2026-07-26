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

@Suite("Reference validation")
struct ReferenceValidationTests {
    let backing = InMemoryDatabase()
    let database: CountingFetches
    let registry: SchemaRegistry
    let store: EntityStore

    init() async throws {
        database = CountingFetches(backing: backing)
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        for parent in ["author", "editor", "agent"] {
            try await registry.publish(
                makeDefinition(
                    entity: parent,
                    fields: [
                        FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                    ]))
            try await store.write(["name": .string(parent)], entity: parent, uuid: "\(parent)-1")
        }
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_00"), references: "author"),
                    FieldDefinition(name: "editor_id", type: .string, storage: .slot(.string, "s_01"), references: "editor"),
                    FieldDefinition(name: "agent_id", type: .string, storage: .slot(.string, "s_02"), references: "agent"),
                ]))
    }

    @Test("A write probes every reference field at once")
    func referenceFieldsProbeConcurrently() async throws {
        let enforcing = EntityStore(database: database, registry: registry, enforceReferences: true)
        database.reset()

        let values: [String: RecordValue] = [
            "author_id": .string("author-1"), "editor_id": .string("editor-1"), "agent_id": .string("agent-1"),
        ]
        try await enforcing.write(values, entity: "book", uuid: "b-1")

        #expect(database.fetches == 3)
        #expect(database.peakInFlight == 3)
    }

    @Test("A broken reference is still reported by field order")
    func brokenReferenceOrder() async throws {
        let enforcing = EntityStore(database: database, registry: registry, enforceReferences: true)

        await #expect(throws: SchemaError.brokenReference(field: "editor_id", key: "editor-9")) {
            let values: [String: RecordValue] = [
                "author_id": .string("author-1"), "editor_id": .string("editor-9"), "agent_id": .string("agent-9"),
            ]
            try await enforcing.write(values, entity: "book", uuid: "b-2")
        }
    }
}

/// Forwards to an in-memory database while recording how many `fetchRecords`
/// calls ran and how many overlapped.
///
/// Each call parks briefly, so overlapping callers are visibly in flight
/// together and a sequential caller never is.
///
final class CountingFetches: CloudDatabase, @unchecked Sendable {
    private let backing: InMemoryDatabase
    private let tally = Tally()

    init(backing: InMemoryDatabase) {
        self.backing = backing
    }

    var fetches: Int {
        tally.total
    }

    var peakInFlight: Int {
        tally.peak
    }

    func reset() {
        tally.reset()
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (total: 0, peak: 0, inFlight: 0)

        var total: Int { lock.withLock { counts.total } }
        var peak: Int { lock.withLock { counts.peak } }

        func enter() {
            lock.withLock {
                counts.total += 1
                counts.inFlight += 1
                counts.peak = Swift.max(counts.peak, counts.inFlight)
            }
        }

        func leave() {
            lock.withLock { counts.inFlight -= 1 }
        }

        func reset() {
            lock.withLock { counts = (0, 0, 0) }
        }
    }

    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        tally.enter()
        defer { tally.leave() }
        try? await Task.sleep(for: .milliseconds(20))
        return try await backing.fetchRecords(ids: ids)
    }

    func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await backing.save(record)
    }

    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws {
        try await backing.modifyRecords(saving: saving, deleting: deleting)
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

    func save(zone: CKRecordZone) async throws {
        try await backing.save(zone: zone)
    }

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await backing.fetchRecord(id: id)
    }

    func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await backing.databaseChanges(since: token)
    }
}
