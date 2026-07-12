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
