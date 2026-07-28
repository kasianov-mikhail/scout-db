//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    /// The records a mirror scenario finds in the zone.
    ///
    /// A restored corpus is handed to the scenario's database outright, so the
    /// records that reach the replica through the store have to be written
    /// first, and that staging is not charged to the measurement.
    ///
    static func stageRecords(_ count: Int) -> @Sendable (PerfWorld) async throws -> Void {
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

    static var offline: [PerfScenario] {
        [
            PerfScenario("Offline cache", "a read the cache has not seen", sql: 1, stack: .offline, writes: false) { world, iteration in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(PerfSchema.products[iteration % PerfSchema.products.count]))
                    .limit(100)
                    .all()
            },
            PerfScenario("Offline cache", "the same read, second time", sql: 2, stack: .offline, writes: false) { world, _ in
                for _ in 0..<2 {
                    _ = try await world.store.query(PerfSchema.order)
                        .filter("product", .equals, .string(world.hotProduct))
                        .limit(100)
                        .all()
                }
            },
            PerfScenario("Offline cache", "write, then flush", sql: 1, stack: .offline) { world, iteration in
                guard let cache = world.offlineCache else { return }
                try await world.store.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("oc", iteration))
                _ = try await cache.flush()
            },
            PerfScenario("Offline cache", "ten writes, one flush", sql: 10, cost: .result, stack: .offline, iterations: 2) { world, iteration in
                guard let cache = world.offlineCache else { return }
                for index in 0..<10 {
                    try await world.store.write(
                        world.newOrder(iteration, offset: index), entity: PerfSchema.order, uuid: world.fresh("of\(index)", iteration))
                }
                _ = try await cache.flush()
            },
        ]
    }

    static var replica: [PerfScenario] {
        [
            PerfScenario(
                "Replica cache", "rebuild a mirror of 500 records", sql: 1, cost: .result, stack: .replica, iterations: 2, setUp: stageRecords(500)
            ) {
                world, _ in
                guard let cache = world.replicaCache else { return }
                _ = try await cache.refresh()
            },
            PerfScenario("Replica cache", "a query answered locally", sql: 1, stack: .replica, writes: false) { world, iteration in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(PerfSchema.products[iteration % PerfSchema.products.count]))
                    .limit(100)
                    .all()
            },
            PerfScenario("Replica cache", "a fetch answered locally", sql: 1, stack: .replica, writes: false) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.order, uuids: world.orders(100, from: iteration))
            },
            PerfScenario("Replica cache", "a write through the mirror", sql: 1, stack: .replica) { world, iteration in
                try await world.store.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("rc", iteration))
            },
        ]
    }
}
