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
        backing.errors = [CKError(.permissionFailure)]
        await #expect(throws: CKError.self) {
            _ = try await store.read(entity: "purchase")
        }
    }

    @Test("A timed-out request and an unusable iCloud account read as offline")
    func offlineFailureShapes() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        for failure in [RequestTimeoutError(seconds: 30), CKError(.notAuthenticated), CKError(.accountTemporarilyUnavailable)] as [any Error] {
            backing.errors = [failure]
            #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-1"])
        }

        backing.errors = [CKError(.internalError, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])]
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-1"])
    }

    @Test("Offline reads by ID are served from the baselines, so a read-modify-write survives")
    func offlineFetchByID() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(try await store.fetch(uuid: "p-1")?.uuid == "p-1")

        backing.errors = Array(repeating: CKError(.networkUnavailable), count: 4)
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.update(entity: "purchase", uuid: "p-1") { $0.values["quantity"] = .int(9) }
        #expect(cache.pendingWrites == 1)

        backing.errors = []
        backing.writeErrors = []
        #expect(try await cache.flush() == 1)
        #expect(try await store.fetch(uuid: "p-1")?.values["quantity"] == .int(9))
    }

    @Test("An ID no baseline covers stays failed offline, rather than reading as absent")
    func offlineFetchOfUncachedID() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.fetch(entity: "purchase", uuids: ["p-1"])

        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.fetch(uuid: "p-2")
        }
        backing.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            _ = try await store.fetch(entity: "purchase", uuids: ["p-1", "p-2"])
        }
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).map(\.uuid) == ["p-1"])
    }

    @Test("An offline read by ID sees the queue and hands out a copy of the cached record")
    func offlineFetchSeesTheQueue() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        _ = try await store.fetch(entity: "purchase", uuids: ["p-1", "p-2"])

        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        try await cache.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: "p-2")])

        backing.errors = Array(repeating: CKError(.networkUnavailable), count: 2)
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1", "p-2"]).map(\.uuid) == ["p-1"])
        let queued = try #require(try await cache.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        #expect(queued["i_01"] == 9)

        queued["i_01"] = 42
        backing.errors = [CKError(.networkUnavailable)]
        let again = try #require(try await cache.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        #expect(again["i_01"] == 9)
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

    @Test("A single update queues offline, a batched one refuses")
    func queuedUpdate() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        backing.writeErrors = [CKError(.networkFailure)]
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        #expect(cache.pendingWrites == 1)
        #expect(try await cache.flush() == 1)
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-1"]).first?.values["quantity"] == .int(9))

        backing.writeErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await store.update(entity: "purchase", uuids: ["p-1", "p-2"]) { record in
                record.values["quantity"] = .int(11)
            }
        }
        #expect(cache.pendingWrites == 0)
    }

    @Test("Offline reads see queued updates and deletes of snapshotted records")
    func readYourWrites() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        #expect(cache.pendingWrites == 2)

        backing.errors = [CKError(.networkUnavailable)]
        let offline = try await store.read(entity: "purchase")
        #expect(offline.map(\.uuid) == ["p-1"])
        #expect(offline.first?.values["quantity"] == .int(9))

        backing.writeErrors = [CKError(.networkFailure)]
        try await store.delete(entity: "purchase", uuid: "p-1")
        backing.errors = [CKError(.networkUnavailable)]
        #expect(try await store.read(entity: "purchase").isEmpty)

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

        first["probe"] = "x"
        guard case .save(let again) = cache.queuedWrites[0] else {
            Issue.record("unexpected queue shape")
            return
        }
        #expect(again["probe"] == nil)

        #expect(cache.discardQueuedWrites(for: first.recordID) == 1)
        #expect(cache.discardQueuedWrites(for: deleteID) == 1)
        #expect(cache.discardQueuedWrites(for: deleteID) == 0)
        #expect(cache.pendingWrites == 1)
        try await cache.flush()
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("A conflict resolver decides overlapping edits the graft cannot merge")
    func conflictResolverMerges() async throws {
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

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(5))
    }

    @Test("Snapshots and the write queue survive a relaunch")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let server = InMemoryDatabase()
        let first = OfflineCache(backing: server, storeURL: url)
        let firstRegistry = SchemaRegistry(database: first)
        let firstStore = EntityStore(database: first, registry: firstRegistry)
        try await firstRegistry.publish(makePurchaseDefinition())
        try await firstStore.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await firstStore.read(entity: "purchase")
        _ = try await SchemaRegistry(database: first).definition(for: "purchase")
        server.writeErrors = [CKError(.networkFailure)]
        try await firstStore.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        #expect(first.pendingWrites == 1)
        first.persistNow()

        let second = OfflineCache(backing: server, storeURL: url)
        #expect(second.pendingWrites == 1)
        let secondStore = EntityStore(database: second, registry: SchemaRegistry(database: second))
        server.errors = [CKError(.networkUnavailable), CKError(.networkUnavailable)]
        #expect(try await secondStore.read(entity: "purchase").map(\.uuid) == ["p-1"])

        try await second.flush()
        #expect(second.pendingWrites == 0)
        #expect(try await secondStore.read(entity: "purchase").map(\.uuid).sorted() == ["p-1", "p-2"])

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

        #expect(OfflineCache(backing: server, storeURL: url).pendingWrites == 1)
    }

    @Test("A legacy single-file archive still restores its queue")
    func legacyArchiveQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-offline-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("queue"))
        }

        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "p-1"))
        let root: [String: Any] = [
            "snapshots": [String: [CKRecord]](), "ops": [["t": "s", "r": record]], "baselines": [CKRecord](),
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true)
        try data.write(to: url)

        let server = InMemoryDatabase()
        #expect(OfflineCache(backing: server, storeURL: url).pendingWrites == 1)
        #expect(OfflineCache(backing: server, storeURL: url).pendingWrites == 1)
    }

    @Test("Both fetch paths defer their archive write, since a baseline is only freshness")
    func fetchesDeferTheArchive() async throws {
        func archivesInline(_ refresh: (OfflineCache, CKRecord.ID) async throws -> Void) async throws -> Bool {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scout-offline-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: url) }

            let server = InMemoryDatabase()
            let seeded = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "p-1"))
            seeded["uuid"] = "p-1"
            try await server.modifyRecords(saving: [seeded], deleting: [])

            let cache = OfflineCache(backing: server, storeURL: url)
            try await refresh(cache, seeded.recordID)
            let inline = FileManager.default.fileExists(atPath: url.path)
            cache.persistNow()
            #expect(FileManager.default.fileExists(atPath: url.path))
            return inline
        }

        #expect(try await archivesInline { cache, id in _ = try await cache.fetchRecord(id: id) } == false)
        #expect(try await archivesInline { cache, id in _ = try await cache.fetchRecords(ids: [id]) } == false)
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

        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["s_00"] = "sku-77"
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["product_id"] == .string("sku-77"))
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("An update read online and queued offline keeps its edit through the merge")
    func flushGraftsAnUpdateReadOnline() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        backing.writeErrors = [CKError(.networkFailure)]
        try await store.update(entity: "purchase", uuid: "p-1") { $0.values["quantity"] = .int(9) }
        #expect(cache.pendingWrites == 1)

        let server = try #require(backing.records.first { $0.recordID.recordName == "p-1" })
        server["s_00"] = "sku-77"
        backing.writeErrors = [RecordConflictError(serverRecord: server.copy() as! CKRecord)]

        #expect(try await cache.flush() == 1)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["product_id"] == .string("sku-77"))
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("A baseline is the record as it was read, not as the caller left it")
    func baselinesAreNotAliased() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let fetched = try #require(try await cache.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        fetched["i_01"] = Int64(99)

        backing.errors = [CKError(.networkUnavailable)]
        let cached = try #require(try await cache.fetchRecord(id: CKRecord.ID(recordName: "p-1")))
        #expect(cached["i_01"] as? Int64 == 3)
    }

    @Test("Flush surfaces an overlapping edit as a conflict instead of overwriting")
    func flushSurfacesOverlappingEdit() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")

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
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(5))
    }

    @Test("A conflict with no remembered baseline surfaces instead of merging")
    func flushWithoutBaselineConflicts() async throws {
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
        var store = ["a": 1, "b": 2, "c": 3, "d": 4]
        var usage: [String: Int64] = ["a": 4, "b": 1, "c": 3, "d": 2]
        OfflineCache.evict(&store, usage: &usage, limit: 2)
        #expect(store.keys.sorted() == ["a", "c"])
        #expect(usage.keys.sorted() == ["a", "c"])

        OfflineCache.evict(&store, usage: &usage, limit: 2)
        #expect(store.keys.sorted() == ["a", "c"])
    }

    @Test("Eviction waits for ten percent overflow, then sheds back to the limit")
    func evictionHysteresis() {
        var store: [String: Int] = [:]
        var usage: [String: Int64] = [:]
        for index in 0..<22 {
            store["k-\(index)"] = index
            usage["k-\(index)"] = Int64(index)
            OfflineCache.evict(&store, usage: &usage, limit: 20)
        }
        #expect(store.count == 22)

        store["k-22"] = 22
        usage["k-22"] = 22
        OfflineCache.evict(&store, usage: &usage, limit: 20)
        #expect(store.count == 20)
        #expect(store["k-0"] == nil)
        #expect(store["k-1"] == nil)
        #expect(store["k-2"] == nil)
    }

    @Test("An evicted baseline degrades a conflicting flush to a surfaced conflict")
    func baselineQuota() async throws {
        let cache = OfflineCache(backing: backing, baselineLimit: 1)
        let store = EntityStore(database: cache, registry: registry)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        _ = try await store.read(entity: "purchase")

        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write(updated, entity: "purchase", uuid: "p-1")
        var updatedTwo = makePurchase(uuid: "p-2").values
        updatedTwo["quantity"] = .int(9)
        try await store.write(updatedTwo, entity: "purchase", uuid: "p-2")

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

        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        var first = makePurchase().values
        first["quantity"] = .int(5)
        try await store.write(first, entity: "purchase", uuid: "p-1")
        var second = makePurchase().values
        second["quantity"] = .int(9)
        try await store.write(second, entity: "purchase", uuid: "p-1")
        #expect(cache.pendingWrites == 2)

        #expect(try await cache.flush() == 1)
        #expect(cache.pendingWrites == 0)
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == .int(9))
    }

    @Test("An offline delete then recreate of one record restores it on flush")
    func deleteThenRecreateKeepsOrder() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        _ = try await store.read(entity: "purchase")

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

    @Test("A flush replays the queue in batches, not a request per record")
    func flushReplaysInBatches() async throws {
        let recorder = Recorder()
        let server = InMemoryDatabase()
        let cache = OfflineCache(backing: ObservedDatabase(backing: server, observer: recorder))
        let registry = SchemaRegistry(database: cache)
        let store = EntityStore(database: cache, registry: registry)
        try await registry.publish(makePurchaseDefinition())

        server.writeErrors = [CKError(.networkFailure)]
        try await store.write((0..<10).map { EntityWrite(values: makePurchase().values, uuid: "p-\($0)") }, entity: "purchase")
        #expect(cache.pendingWrites == 10)

        recorder.reset()
        #expect(try await cache.flush() == 10)
        #expect(recorder.operations.filter { $0.kind == .conditionalSave }.count == 1)
        #expect(cache.pendingWrites == 0)
        #expect(try await store.read(entity: "purchase").count == 10)
    }

    @Test("A batch the server calls too large is bisected, not retried a record at a time")
    func flushBisectsAnOversizedBatch() async throws {
        let server = InMemoryDatabase()
        let probe = BatchProbe(backing: server, saveLimit: 25)
        let cache = OfflineCache(backing: probe)
        let registry = SchemaRegistry(database: cache)
        let store = EntityStore(database: cache, registry: registry)
        try await registry.publish(makePurchaseDefinition())

        server.writeErrors = [CKError(.networkFailure)]
        try await store.write((0..<50).map { EntityWrite(values: makePurchase().values, uuid: "p-\($0)") }, entity: "purchase")
        #expect(cache.pendingWrites == 50)

        #expect(try await cache.flush() == 50)
        #expect(probe.saveBatches == [50, 25, 25])
        #expect(cache.pendingWrites == 0)
        #expect(try await store.read(entity: "purchase").count == 50)
    }

    @Test("Records that lose the first round rejoin one merge batch, not a request each")
    func flushRebatchesContestedSaves() async throws {
        let server = InMemoryDatabase()
        let probe = BatchProbe(backing: server)
        let cache = OfflineCache(backing: probe)
        let registry = SchemaRegistry(database: cache)
        let store = EntityStore(database: cache, registry: registry)
        try await registry.publish(makePurchaseDefinition())

        try await store.write((0..<5).map { EntityWrite(values: makePurchase().values, uuid: "p-\($0)") }, entity: "purchase")
        _ = try await store.read(entity: "purchase")

        server.writeErrors = [CKError(.networkFailure)]
        var updated = makePurchase().values
        updated["quantity"] = .int(9)
        try await store.write((0..<5).map { EntityWrite(values: updated, uuid: "p-\($0)") }, entity: "purchase")

        let other = EntityStore(database: server, registry: SchemaRegistry(database: server))
        for index in 0..<5 {
            try await other.update(entity: "purchase", uuid: "p-\(index)") { $0.values["product_id"] = .string("sku-77") }
        }

        #expect(try await cache.flush() == 5)
        #expect(probe.saveBatches == [5, 5])
        #expect(cache.pendingWrites == 0)
        let records = try await store.read(entity: "purchase")
        #expect(records.allSatisfy { $0.values["quantity"] == .int(9) && $0.values["product_id"] == .string("sku-77") })
    }

    @Test("More queued deletions than one request holds replay in batches")
    func flushChunksDeletions() async throws {
        let server = InMemoryDatabase()
        let probe = BatchProbe(backing: server)
        let cache = OfflineCache(backing: probe)
        let ids = (0..<450).map { CKRecord.ID(recordName: "gone-\($0)") }

        server.writeErrors = [CKError(.networkFailure)]
        try await cache.modifyRecords(saving: [], deleting: ids)
        #expect(cache.pendingWrites == 450)

        probe.reset()
        #expect(try await cache.flush() == 450)
        #expect(probe.deleteBatches == [400, 50])
        #expect(cache.pendingWrites == 0)
    }

    @Test("A permanently rejected write surfaces without wedging the queue behind it")
    func poisonWriteDoesNotStall() async throws {
        backing.writeErrors = [CKError(.networkFailure), CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "poison")
        try await store.write(makePurchase(uuid: "good").values, entity: "purchase", uuid: "good")
        #expect(cache.pendingWrites == 2)

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

final class BatchProbe: CloudDatabase, @unchecked Sendable {
    let backing: InMemoryDatabase
    let saveLimit: Int?
    private let lock = NSLock()
    private var saves: [Int] = []
    private var deletes: [Int] = []

    init(backing: InMemoryDatabase, saveLimit: Int? = nil) {
        self.backing = backing
        self.saveLimit = saveLimit
    }

    var saveBatches: [Int] { lock.withLock { saves } }
    var deleteBatches: [Int] { lock.withLock { deletes } }

    func reset() {
        lock.withLock {
            saves = []
            deletes = []
        }
    }

    func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        lock.withLock { saves.append(records.count) }
        if let saveLimit, records.count > saveLimit {
            throw CKError(.limitExceeded)
        }
        return try await backing.saveIfUnchanged(records)
    }

    func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        if recordIDs.count > 0 {
            lock.withLock { deletes.append(recordIDs.count) }
        }
        try await backing.modifyRecords(saving: records, deleting: recordIDs)
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

    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try await backing.fetchRecords(ids: ids)
    }
}
