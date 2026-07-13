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

@Suite("Offline cache")
struct OfflineCacheTests {
    let backing = InMemoryDatabase()
    let cache: OfflineCache
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        cache = OfflineCache(backing: backing)
        registry = SchemaRegistry(database: cache)
        store = EntityStore(database: cache, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("Reads fall back to the last complete response when the network fails")
    func staleReads() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let online = try await store.read(entity: "purchase")
        #expect(online.map(\.uuid) == ["p-1"])

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.map(\.uuid) == ["p-1"])
    }

    @Test("An uncached query stays failed offline, and non-network errors pass through")
    func uncachedRead() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase", filters: [.init(field: "quantity", op: .equals, value: .int(3))])
        }

        _ = try await store.read(entity: "purchase")
        backing.errors = [CKError(.notAuthenticated)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase")
        }
    }

    @Test("Offline writes queue and flush replays them")
    func queuedWrites() async throws {
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 1)
        #expect(backing.records.filter { $0.recordType == "Entity" }.isEmpty)

        let flushed = try await cache.flush()
        #expect(flushed == 1)
        #expect(cache.pendingWrites == 0)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-1"])
        #expect(try await cache.flush() == 0)
    }

    @Test("Offline reads see queued updates and deletes of snapshotted records")
    func readYourWrites() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        // Queue offline writes: a rewrite of p-1 and a brand-new p-2.
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        #expect(cache.pendingWrites == 2)

        // The offline read serves the queued rewrite; the new record cannot join
        // the snapshot — its predicate cannot run offline.
        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.map(\.uuid) == ["p-1"])
        #expect(offline.first?.values["quantity"] == .int(9))

        // A queued tombstone drops the record from offline reads too.
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.delete(entity: "purchase", uuid: "p-1")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").isEmpty)

        // Back online, the flush reconciles everything.
        try await cache.flush()
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("Snapshots and the write queue survive a relaunch")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        // First launch: snapshot a read, queue an offline write.
        let server = InMemoryDatabase()
        let first = OfflineCache(backing: server, storeURL: url)
        let firstRegistry = SchemaRegistry(database: first)
        let firstStore = EntityStore(database: first, registry: firstRegistry)
        try await firstRegistry.publish(makePurchaseDefinition())
        try await firstStore.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await firstStore.read(entity: "purchase")
        // Snapshot the schema descriptor too — the relaunched registry reads it offline.
        _ = try await SchemaRegistry(database: first).definition(for: "purchase")
        server.writeErrors = [CKError(.networkFailure)]
        try await firstStore.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        #expect(first.pendingWrites == 1)

        // Second launch restores both: the offline read and the pending queue.
        let second = OfflineCache(backing: server, storeURL: url)
        #expect(second.pendingWrites == 1)
        let secondStore = EntityStore(database: second, registry: SchemaRegistry(database: second))
        server.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable)]
        #expect(try await secondStore.read(entity: "purchase").map(\.uuid) == ["p-1"])

        try await second.flush()
        #expect(second.pendingWrites == 0)
        #expect(try await secondStore.read(entity: "purchase").map(\.uuid).sorted() == ["p-1", "p-2"])

        // The flushed state persists too: a third launch starts clean.
        #expect(OfflineCache(backing: server, storeURL: url).pendingWrites == 0)
    }

    @Test("Flush grafts disjoint offline edits onto a server record that moved")
    func flushGraftsDisjointEdits() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 1)

        // Another client renamed the product while this one was offline: the
        // two edits touch disjoint fields, so the flush merges instead of
        // overwriting the rename.
        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["s_00"] = "sku-77"
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["product_id"] == .string("sku-77"))
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("Flush surfaces an overlapping edit as a conflict instead of overwriting")
    func flushSurfacesOverlappingEdit() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

        // Another client moved the same field to a different value.
        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["i_01"] = 5
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        do {
            try await cache.flush()
            Issue.record("Expected an OfflineFlushError")
        } catch let error as OfflineFlushError {
            #expect(error.conflicts.count == 1)
            #expect(error.conflicts.first?.queued["i_01"] == 9)
            #expect(error.conflicts.first?.server["i_01"] == 5)
        }
        // The conflicted write left the queue and the server's edit survived.
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(5))
    }

    @Test("A conflict with no remembered baseline surfaces instead of merging")
    func flushWithoutBaselineConflicts() async throws {
        // No read happens before the offline edit, so the cache has no merge
        // base to prove the edits disjoint — even a disjoint-looking conflict
        // must surface.
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["s_00"] = "sku-77"
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        await #expect(throws: OfflineFlushError.self) {
            try await cache.flush()
        }
        #expect(cache.pendingWrites == 0)
    }

    @Test("A flush that fails keeps the queue intact")
    func failedFlush() async throws {
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 1)

        // The replay talks to the backing database directly, so an offline
        // failure surfaces and the queue survives for the next attempt.
        backing.writeErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await cache.flush()
        }
        #expect(cache.pendingWrites == 1)
    }
}
