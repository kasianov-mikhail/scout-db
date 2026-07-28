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
    static var offline: [PerfScenario] {
        [
            PerfScenario("Offline cache", "a read the cache has not seen", sql: 1, stack: .offline, writes: false) { world, iteration in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(PerfSchema.products[iteration % PerfSchema.products.count]))
                    .limit(100)
                    .all()
            },
            PerfScenario(
                "Offline cache", "the same read, cache warm", sql: 1, stack: .offline, writes: false,
                setUp: { world in
                    _ = try await world.store.query(PerfSchema.order)
                        .filter("product", .equals, .string(world.hotProduct))
                        .limit(100)
                        .all()
                }
            ) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .limit(100)
                    .all()
            },
            PerfScenario(
                "Offline cache", "flush one queued write", sql: 1, stack: .offline, iterations: 1,
                setUp: { world in
                    world.backing.writeErrors = [CKError(.networkFailure)]
                    try await world.store.write(world.newOrder(0), entity: PerfSchema.order, uuid: world.fresh("oc", 0))
                }
            ) { world, _ in
                guard let cache = world.offlineCache else { return }
                _ = try await cache.flush()
            },
        ]
    }
}
