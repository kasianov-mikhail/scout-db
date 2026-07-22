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

    @Test("The queue is inspectable and a record's pending writes can be discarded")
    func queueInspection() async throws {
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let deleteID = CKRecord.ID(recordName: "gone")
        backing.writeErrors = [CKError(.networkFailure)]
        try await cache.modifyRecords(saving: [], deleting: [deleteID])

        let queued = cache.queuedWrites
        #expect(queued.count == 3)
        guard case .save(let first) = queued[0], case .delete(let deleted) = queued[2] else {
            Issue.record("unexpected queue shape")
            return
        }
        #expect(deleted == deleteID)

        // The reported record is a copy — editing it does not edit the queue.
        first["probe"] = "x"
        guard case .save(let again) = cache.queuedWrites[0] else {
            Issue.record("unexpected queue shape")
            return
        }
        #expect(again["probe"] == nil)

        // Discarding drops the entry; the flush replays only what remains.
        #expect(cache.discardQueuedWrites(for: first.recordID) == 1)
        #expect(cache.discardQueuedWrites(for: deleteID) == 1)
        #expect(cache.discardQueuedWrites(for: deleteID) == 0)
        #expect(cache.pendingWrites == 1)
        try await cache.flush()
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("A conflict resolver decides overlapping edits the graft cannot merge")
    func conflictResolverMerges() async throws {
        // The larger quantity wins a two-sided edit of the same field.
        struct LargerQuantityWins: ConflictResolver {
            func resolve(queued: CKRecord, server: CKRecord, ancestor: CKRecord?) -> ConflictResolution {
                let merged = server.copy() as! CKRecord
                merged["i_01"] = max((queued["i_01"] as? Int64) ?? 0, (server["i_01"] as? Int64) ?? 0)
                return .save(merged)
            }
        }
        let cache = OfflineCache(backing: backing, conflictResolver: LargerQuantityWins())
        let store = EntityStore(database: cache, registry: SchemaRegistry(database: cache))

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

        // Another client moved the same field: the graft cannot merge, the
        // resolver picks the larger value and the flush lands it.
        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["i_01"] = 5
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("A decoded resolver reads and writes field names, not slots")
    func decodedConflictResolver() async throws {
        let cache = OfflineCache(backing: backing)
        let store = EntityStore(database: cache, registry: SchemaRegistry(database: cache))
        cache.setConflictResolver(
            store.conflictResolver { queued, server, ancestor in
                // The merge base is decoded too, and the policy speaks schema
                // field names — no storage slots in sight.
                #expect(ancestor != nil)
                let mine: Int64 = queued["quantity"] ?? 0
                let theirs: Int64 = server["quantity"] ?? 0
                var merged = server
                merged.values["quantity"] = .int(max(mine, theirs))
                return .save(merged)
            })

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

        // Another client moved the same field: the graft cannot merge, the
        // decoded policy takes the larger quantity and the flush lands it.
        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["i_01"] = 5
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("A resolver keeping the server copy retires the queued write")
    func conflictResolverKeepsServer() async throws {
        struct ServerWins: ConflictResolver {
            func resolve(queued: CKRecord, server: CKRecord, ancestor: CKRecord?) -> ConflictResolution {
                .keepServer
            }
        }
        let cache = OfflineCache(backing: backing, conflictResolver: ServerWins())
        let store = EntityStore(database: cache, registry: SchemaRegistry(database: cache))

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["i_01"] = 5
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        // The flush retires the queued write without touching the server copy.
        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(5))
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

    @Test("A queued offline write is archived without waiting for the delayed write")
    func queuedWritesArchiveImmediately() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let server = InMemoryDatabase()
        let cache = OfflineCache(backing: server, storeURL: url)
        let registry = SchemaRegistry(database: cache)
        let store = EntityStore(database: cache, registry: registry)
        try await registry.publish(makePurchaseDefinition())

        server.writeErrors = [CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        // The caller was told this write succeeded, so it has to be on disk
        // already — nothing forces the archive here, and a crash now would
        // otherwise lose a write the app believes it made.
        #expect(OfflineCache(backing: server, storeURL: url).pendingWrites == 1)
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

    @Test("An offline-queued asset write survives the staged file's retirement")
    func queuedAssetWriteSurvivesRetirement() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "report",
                fields: [FieldDefinition(name: "dump", type: .asset, storage: .slot(.asset, "a_00"))]))
        let payload = Data("offline-\(UUID().uuidString)".utf8)

        // The write queues offline and reports success, so the store retires
        // its staged file; the queue must hold its own copy of the bytes.
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.write(["dump": .bytes(payload)], entity: "report", uuid: "r-1")
        #expect(cache.pendingWrites == 1)

        try await cache.flush()
        let record = try #require(try await store.read(entity: "report").first)
        #expect(try record.assetData(for: "dump") == payload)
    }

    @Test("Flush merges honestly against a genuinely moved server record")
    func flushMergesHonestly() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 1)

        // Another client really lands a disjoint edit — no injected conflict;
        // the double's own change-tag comparison must surface it to the flush.
        let other = EntityStore(database: backing, registry: SchemaRegistry(database: backing))
        try await other.update(entity: "purchase", uuid: "p-1") { $0.values["product_id"] = .string("sku-77") }

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["product_id"] == .string("sku-77"))
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("The snapshot quota evicts the least recently used query")
    func snapshotQuota() async throws {
        let cache = OfflineCache(backing: backing, snapshotLimit: 2)
        let store = EntityStore(database: cache, registry: registry)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        // Three distinct queries; re-touching the first makes the second the
        // LRU victim when the third arrives.
        let q1: [EntityStore.Filter] = []
        let q2: [EntityStore.Filter] = [.init(field: "quantity", op: .greaterThan, value: .int(0))]
        let q3: [EntityStore.Filter] = [.init(field: "quantity", op: .lessThan, value: .int(9))]
        _ = try await store.read(entity: "purchase", filters: q1)
        _ = try await store.read(entity: "purchase", filters: q2)
        _ = try await store.read(entity: "purchase", filters: q1)
        _ = try await store.read(entity: "purchase", filters: q3)

        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase", filters: q1).map(\.uuid) == ["p-1"])
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase", filters: q3).map(\.uuid) == ["p-1"])
        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase", filters: q2)
        }
    }

    @Test("Eviction sheds the whole overflow at once, least recently used first")
    func evictionOrder() {
        // Four entries against a quota of two: the overflow leaves in one pass,
        // which is the restore path's shape — an oversized archive never sheds
        // its entries one at a time.
        var store = ["a": 1, "b": 2, "c": 3, "d": 4]
        var usage: [String: Int64] = ["a": 4, "b": 1, "c": 3, "d": 2]
        OfflineCache.evict(&store, usage: &usage, limit: 2)
        #expect(store.keys.sorted() == ["a", "c"])
        // The recency bookkeeping follows the entries out; a stale usage entry
        // would keep ranking a key that no longer exists.
        #expect(usage.keys.sorted() == ["a", "c"])

        // Already within quota: nothing moves.
        OfflineCache.evict(&store, usage: &usage, limit: 2)
        #expect(store.keys.sorted() == ["a", "c"])
    }

    @Test("An evicted baseline degrades a conflicting flush to a surfaced conflict")
    func baselineQuota() async throws {
        let cache = OfflineCache(backing: backing, baselineLimit: 1)
        let store = EntityStore(database: cache, registry: registry)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        // Both baselines arrive in one read; only the newer (p-2) survives.
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        var updatedTwo = makePurchase(uuid: "p-2").values
        updatedTwo["quantity"] = .int(9)
        try await store.write(updatedTwo, entity: "purchase", uuid: "p-2")

        // Both servers move on a disjoint field: with a baseline the flush
        // grafts, without one it must surface the conflict.
        for uuid in ["p-1", "p-2"] {
            let server = try #require(backing.records.first { $0.recordID.recordName == uuid })
            server["s_00"] = "sku-77"
        }
        let conflicts = [
            RecordConflictError(serverRecord: backing.records.first { $0.recordID.recordName == "p-2" }!.copy() as! CKRecord),
            RecordConflictError(serverRecord: backing.records.first { $0.recordID.recordName == "p-1" }!.copy() as! CKRecord),
        ]
        backing.writeErrors = conflicts

        do {
            try await cache.flush()
            Issue.record("Expected an OfflineFlushError")
        } catch let error as OfflineFlushError {
            #expect(error.conflicts.map { $0.queued.recordID.recordName } == ["p-1"])
        }
        let merged = try #require(backing.records.first { $0.recordID.recordName == "p-2" })
        #expect(merged["i_01"] == 9)
        #expect(merged["s_00"] == "sku-77")
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

    @Test("Repeated offline edits of one record flush to the latest without a self-conflict")
    func coalescesRepeatedSaves() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        // Two offline edits of the same record touching the same field.
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var first = makePurchase().values
        first["quantity"] = .int(5)
        try await store.write(first, entity: "purchase", uuid: "p-1")
        var second = makePurchase().values
        second["quantity"] = .int(9)
        try await store.write(second, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 2)

        // Only the latest edit replays, so it never conflicts against its own
        // earlier queued copy: the server ends at 9, not stuck at 5.
        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("An offline delete then recreate of one record restores it on flush")
    func deleteThenRecreateKeepsOrder() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        // Delete p-1, then recreate it — the recreate is the later op and wins.
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        try await store.delete(entity: "purchase", uuid: "p-1")
        var revived = makePurchase().values
        revived["quantity"] = .int(7)
        try await store.write(revived, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 2)

        try await cache.flush()
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.uuid == "p-1")
        #expect(record.values["quantity"] == .int(7))
    }

    @Test("A permanently rejected write surfaces without wedging the queue behind it")
    func poisonWriteDoesNotStall() async throws {
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "poison")
        try await store.write(makePurchase(uuid: "good").values, entity: "purchase", uuid: "good")
        #expect(cache.pendingWrites == 2)

        // The first replayed save is rejected for a non-transport reason; the
        // second is valid. The bad one is surfaced as a failure, both leave the
        // queue, and the good write still lands — it is not stuck behind the
        // poison forever.
        backing.writeErrors = [CKError(.permissionFailure)]
        do {
            try await cache.flush()
            Issue.record("Expected an OfflineFlushError")
        } catch let error as OfflineFlushError {
            #expect(error.failures.count == 1)
            #expect(error.conflicts.isEmpty)
        }
        #expect(cache.pendingWrites == 0)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["good"])
    }
}
