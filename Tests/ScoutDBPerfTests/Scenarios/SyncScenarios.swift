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
    static var liveQueries: [PerfScenario] {
        [
            PerfScenario("Live queries", "the first snapshot", sql: 1, cost: .result, writes: false, iterations: 2) { world, _ in
                for try await _ in world.store.observe(entity: PerfSchema.order, filters: [.init(field: "status", op: .equals, value: .string("paid"))]) {
                    return
                }
            },
            PerfScenario("Live queries", "a snapshot, a write, and the fold after it", sql: 3, cost: .result, iterations: 2) { world, iteration in
                let stream = world.store.observe(entity: PerfSchema.order, filters: [.init(field: "status", op: .equals, value: .string("paid"))])
                var iterator = stream.makeAsyncIterator()
                _ = try await iterator.next()
                try await world.store.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("live", iteration))
                _ = try await iterator.next()
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
