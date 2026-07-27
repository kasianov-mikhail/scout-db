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
            PerfScenario("Aggregation", "aggregate(daily) over 30 days", sql: 1, cost: .result, writes: false) { world, _ in
                let window = world.window(days: 30)
                _ = try await world.store.aggregate(entity: PerfSchema.order, view: "daily", from: window.from, to: window.to)
            },
            PerfScenario("Aggregation", "aggregate(daily) over 18 months", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.aggregate(entity: PerfSchema.order, view: "daily")
            },
            PerfScenario("Aggregation", "series(daily) over 90 days", sql: 1, cost: .result, writes: false) { world, _ in
                let window = world.window(days: 90)
                _ = try await world.store.series(entity: PerfSchema.order, view: "daily", from: window.from, to: window.to)
            },
            PerfScenario("Aggregation", "totals(revenue)", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.totals(entity: PerfSchema.order, view: "revenue")
            },
            PerfScenario("Aggregation", "totals(peak) with a predicate", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.totals(entity: PerfSchema.order, view: "peak") { $0.count > 10 }
            },
            PerfScenario("Aggregation", "percentile(0.95) from a histogram", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.percentile(0.95, entity: PerfSchema.order, view: "spend")
            },
            PerfScenario("Aggregation", "distinct(product)", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.distinct(entity: PerfSchema.order, field: "product")
            },
            PerfScenario("Aggregation", "distinct(country) of customers", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.distinct(entity: PerfSchema.customer, field: "country")
            },
            PerfScenario("Aggregation", "lifetime totals by country", sql: 1, cost: .result, writes: false) { world, _ in
                _ = try await world.store.totals(entity: PerfSchema.customer, view: "by_country")
            },
            PerfScenario("Grid", "write ten orders across ten slots", sql: 1, cost: .result) { world, iteration in
                let batch = (0..<10).map { index in
                    EntityWrite(values: world.newOrder(iteration, offset: index), uuid: world.fresh("grid\(index)", iteration))
                }
                try await world.store.write(batch, entity: PerfSchema.order)
            },
            PerfScenario("Grid", "write ten orders into one slot", sql: 1, cost: .result) { world, iteration in
                let batch = (0..<10).map { index in
                    var values = world.newOrder(iteration)
                    values["product"] = .string(world.hotProduct)
                    values["date"] = .date(world.corpus.now)
                    values["total"] = .double(10 + Double(index))
                    return EntityWrite(values: values, uuid: world.fresh("hot\(index)", iteration))
                }
                try await world.store.write(batch, entity: PerfSchema.order)
            },
            PerfScenario("Grid", "update that cannot move a max", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.order(iteration)) { record in
                    record.values["total"] = .double(1)
                }
            },
        ]
    }
}
