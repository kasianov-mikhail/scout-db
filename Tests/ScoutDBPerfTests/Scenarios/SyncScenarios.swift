//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var subscriptions: [PerfScenario] {
        [
            PerfScenario("Subscriptions", "subscribe to an entity", sql: 1) { world, iteration in
                _ = try await world.store.query(PerfSchema.order).subscribe(id: world.fresh("sub", iteration))
            },
            PerfScenario("Subscriptions", "subscribe with a projection", sql: 1) { world, iteration in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("status" == "paid")
                    .subscribe(id: world.fresh("prj", iteration), projecting: ["product", "total"])
            },
            PerfScenario("Subscriptions", "list the subscriptions", sql: 1, writes: false) { world, _ in
                _ = try await world.store.subscriptions()
            },
            PerfScenario(
                "Subscriptions", "unsubscribe", sql: 1,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let id = world.fresh("drop", iteration)
                        _ = try await world.store.query(PerfSchema.item).subscribe(id: id)
                        world.stage.uuids.append(id)
                    }
                }
            ) { world, iteration in
                try await world.store.unsubscribe(id: world.stage.uuids[iteration])
            },
        ]
    }

    static var pushEvents: [PerfScenario] {
        [
            PerfScenario("Push events", "an update push, resolved by fetch", sql: 1, writes: false) { world, iteration in
                guard let event = ChangeEvent(reason: .recordUpdated, recordName: world.order(iteration), subscriptionID: "perf") else {
                    return
                }
                _ = try await world.store.record(for: event)
            },
            PerfScenario("Push events", "a hard-delete push", sql: 0, writes: false) { world, iteration in
                guard let event = ChangeEvent(reason: .recordDeleted, recordName: world.order(iteration), subscriptionID: "perf") else {
                    return
                }
                _ = try await world.store.record(for: event)
            },
        ]
    }
}
