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

@Suite("Observed database")
struct ObservedDatabaseTests {
    let backing = InMemoryDatabase()
    let recorder = Recorder()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        let observed = ObservedDatabase(backing: backing, observer: recorder)
        registry = SchemaRegistry(database: observed)
        store = EntityStore(database: observed, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("Store traffic reaches the observer with kinds and counts")
    func observesStoreTraffic() async throws {
        recorder.reset()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let read = try await store.read(entity: "purchase")
        #expect(read.count == 1)

        let modify = try #require(recorder.operations.first { $0.kind == .modify })
        #expect(modify.recordCount == 1)
        #expect(modify.error == nil)
        #expect(modify.duration >= .zero)
        let query = try #require(recorder.operations.last { $0.kind == .query })
        #expect(query.recordCount == 1)
    }

    @Test("A failing call reports its error and still throws")
    func observesFailures() async throws {
        recorder.reset()
        backing.writeErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        }

        let failed = try #require(recorder.operations.first { $0.error != nil })
        #expect(failed.kind == .modify)
        #expect(failed.error?.contains("CKError") == true)
    }

    @Test("The decorator composes around the offline cache")
    func composesWithOfflineCache() async throws {
        let recorder = Recorder()
        let observed = ObservedDatabase(backing: OfflineCache(backing: backing), observer: recorder)
        let registry = SchemaRegistry(database: observed)
        let store = EntityStore(database: observed, registry: registry)
        try await registry.publish(makePurchaseDefinition())
        recorder.reset()

        // The queued offline write is reported as the success the caller saw.
        backing.writeErrors = [CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let modify = try #require(recorder.operations.first { $0.kind == .modify })
        #expect(modify.error == nil)
    }
}

// Collects reported operations from any thread.
final class Recorder: DatabaseObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [DatabaseOperation] = []

    var operations: [DatabaseOperation] {
        lock.withLock { collected }
    }

    func record(_ operation: DatabaseOperation) {
        lock.withLock { collected.append(operation) }
    }

    func reset() {
        lock.withLock { collected = [] }
    }
}
