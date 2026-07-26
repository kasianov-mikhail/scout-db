//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

extension PerfScenarios {
    /// The change feed a sync scenario drains.
    ///
    /// A restored corpus carries no feed — the double logs a change when a
    /// record is written through it, and the scenario's database was handed the
    /// records outright. So each sync scenario stages its own feed first, and
    /// the staging is not charged to the measurement.
    ///
    static func stageFeed(_ count: Int) -> @Sendable (PerfWorld) async throws -> Void {
        { world in
            let batch = (0..<count).map { index in
                let values: [String: RecordValue] = [
                    "order": .string(world.order(index)),
                    "sku": .string(PerfSchema.products[index % PerfSchema.products.count]),
                    "quantity": .int(1),
                    "price": .double(4.99),
                    "added": .date(world.corpus.now),
                ]
                return EntityWrite(values: values, uuid: "feed-\(world.runID)-\(index)")
            }
            try await world.store.write(batch, entity: PerfSchema.item)
        }
    }

    static var zoneSync: [PerfScenario] {
        [
            PerfScenario("Zone sync", "drain a feed of 200 changes", sql: 1, writes: false, iterations: 2, setUp: stageFeed(200)) { world, _ in
                _ = try await world.store.zoneChanges()
            },
            PerfScenario("Zone sync", "drain a feed of 1000 changes", sql: 1, writes: false, iterations: 2, setUp: stageFeed(1_000)) { world, _ in
                _ = try await world.store.zoneChanges()
            },
            PerfScenario("Zone sync", "incremental after twenty writes", sql: 3, iterations: 2, setUp: stageFeed(200)) { world, iteration in
                let token = try await world.store.zoneChanges().token
                let batch = (0..<20).map { index in
                    EntityWrite(values: world.newOrder(iteration, offset: index), uuid: world.fresh("z\(index)", iteration))
                }
                try await world.store.write(batch, entity: PerfSchema.order)
                _ = try await world.store.zoneChanges(since: token)
            },
            PerfScenario("Zone sync", "batched feed, 500 a batch", sql: 2, writes: false, iterations: 2, setUp: stageFeed(1_000)) { world, _ in
                for try await _ in world.store.zoneChanges(batchSize: 500) {
                    continue
                }
            },
            PerfScenario("Zone sync", "projected feed of 1000", sql: 1, writes: false, iterations: 2, setUp: stageFeed(1_000)) { world, _ in
                _ = try await world.store.zoneChanges(
                    projecting: [
                        SyncProjection(entity: PerfSchema.item, fields: ["sku"]),
                        SyncProjection(entity: PerfSchema.order, fields: ["product", "total"]),
                    ])
            },
        ]
    }

    static var coordinator: [PerfScenario] {
        [
            PerfScenario("Sync coordinator", "one pass over 200 changes", sql: 1, iterations: 2, setUp: stageFeed(200)) { world, _ in
                let coordinator = SyncCoordinator(store: world.store)
                _ = try await coordinator.sync()
            },
            PerfScenario("Sync coordinator", "four passes coalescing", sql: 1, iterations: 1, setUp: stageFeed(200)) { world, _ in
                let coordinator = SyncCoordinator(store: world.store)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 {
                        group.addTask { _ = try await coordinator.sync() }
                    }
                    try await group.waitForAll()
                }
            },
            PerfScenario("Sync coordinator", "a pass after a local write", sql: 3, iterations: 2, setUp: stageFeed(200)) { world, iteration in
                let coordinator = SyncCoordinator(store: world.store)
                _ = try await coordinator.sync()
                try await world.store.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("sc", iteration))
                _ = try await coordinator.sync()
            },
        ]
    }

    static var liveQueries: [PerfScenario] {
        [
            PerfScenario("Live queries", "the first snapshot", sql: 1, writes: false, iterations: 2) { world, _ in
                for try await _ in world.store.observe(entity: PerfSchema.order, filters: [.init(field: "status", op: .equals, value: .string("paid"))]) {
                    return
                }
            },
            PerfScenario("Live queries", "a re-query after one write", sql: 3, iterations: 2) { world, iteration in
                let stream = world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .limit(50)
                    .observe()
                var iterator = stream.makeAsyncIterator()
                _ = try await iterator.next()
                try await world.store.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("lq", iteration))
                _ = try await iterator.next()
            },
        ]
    }

    static var subscriptions: [PerfScenario] {
        [
            PerfScenario("Subscriptions", "subscribe to an entity", sql: 1) { world, iteration in
                _ = try await world.store.subscribe(entity: PerfSchema.order, filters: [], id: world.fresh("sub", iteration))
            },
            PerfScenario("Subscriptions", "subscribe with a projection", sql: 1) { world, iteration in
                _ = try await world.store.subscribe(
                    entity: PerfSchema.order, filters: [.init(field: "status", op: .equals, value: .string("paid"))], id: world.fresh("prj", iteration),
                    projecting: ["product", "total"])
            },
            PerfScenario("Subscriptions", "list, then drop one", sql: 3) { world, iteration in
                let id = world.fresh("drop", iteration)
                _ = try await world.store.subscribe(entity: PerfSchema.item, id: id)
                _ = try await world.store.subscriptions()
                try await world.store.unsubscribe(id: id)
            },
            PerfScenario("Subscriptions", "one database subscription", sql: 1) { world, iteration in
                _ = try await world.store.subscribeToDatabase(id: world.fresh("db", iteration))
            },
        ]
    }

    static var pushEvents: [PerfScenario] {
        [
            PerfScenario("Push events", "an update push, resolved by fetch", sql: 1, writes: false) { world, iteration in
                guard let event = ChangeEvent(reason: .recordUpdated, recordName: world.order(iteration), subscriptionID: "perf") else { return }
                _ = try await world.store.record(for: event)
            },
            PerfScenario("Push events", "a hard-delete push", sql: 0, writes: false) { world, iteration in
                guard let event = ChangeEvent(reason: .recordDeleted, recordName: world.order(iteration), subscriptionID: "perf") else { return }
                _ = try await world.store.record(for: event)
            },
        ]
    }
}
