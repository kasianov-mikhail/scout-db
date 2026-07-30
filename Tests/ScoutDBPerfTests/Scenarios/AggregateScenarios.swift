//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var aggregates: [PerfScenario] {
        [
            PerfScenario("Aggregation", "totals(daily) over 30 days", sql: 1, writes: false) { world, _ in
                let window = world.window(days: 30)
                _ = try await world.store.query(PerfSchema.order).totals(by: "product", bucket: .day, from: window.from, to: window.to)
            },
            PerfScenario("Aggregation", "totals(daily) over 18 months", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).totals(by: "product", bucket: .day)
            },
            PerfScenario("Aggregation", "series(daily) over 90 days", sql: 1, writes: false) { world, _ in
                let window = world.window(days: 90)
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "daily", from: window.from, to: window.to).series()
            },
            PerfScenario("Aggregation", "totals(revenue)", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "revenue").totals()
            },
            PerfScenario("Aggregation", "totals(peak) with a predicate", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "peak").totals() { $0.count > 10 }
            },
            PerfScenario("Aggregation", "percentile(0.95) from a histogram", sql: 1, writes: false) { world, _ in
                _ = try await GridQuery(world.store, entity: PerfSchema.order, view: "spend").percentile(0.95)
            },
            PerfScenario("Aggregation", "distinct(product)", sql: 1, writes: false) { world, _ in
                _ = try await world.store.distinct(entity: PerfSchema.order, field: "product")
            },
            PerfScenario("Aggregation", "distinct(country) of customers", sql: 1, writes: false) { world, _ in
                _ = try await world.store.distinct(entity: PerfSchema.customer, field: "country")
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
