//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
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
}
