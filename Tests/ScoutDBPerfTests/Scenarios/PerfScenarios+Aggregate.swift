//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var aggregates: [PerfScenario] {
        [
            PerfScenario("Aggregation", "totals by product", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).totals("total", by: "product")
            },
            PerfScenario("Aggregation", "totals(revenue)", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "revenue").totals()
            },
            PerfScenario("Aggregation", "totals(peak)", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "peak").totals()
            },
            PerfScenario("Aggregation", "lifetime totals by country", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.customer, view: "by_country").totals()
            },
            PerfScenario("Grid", "update that cannot move a max", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.order(iteration)) { record in
                    record.values["total"] = .double(1)
                }
            },
        ]
    }
}
