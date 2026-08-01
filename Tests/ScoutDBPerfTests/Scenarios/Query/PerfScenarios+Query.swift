//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var queries: [PerfScenario] {
        [
            PerfScenario("Queries", "take 200 of one product", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .take(200)
            },
            PerfScenario("Queries", "filter + sort + take 20", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("status", .equals, .string("paid"))
                    .sort("total", .descending)
                    .take(20)
            },
            PerfScenario("Queries", "OR group of three products, take 50", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter(
                        "product" == .string(PerfSchema.products[0]) || "product" == .string(PerfSchema.products[1])
                            || "product" == .string(PerfSchema.products[2])
                    )
                    .take(50)
            },
            PerfScenario("Queries", "OR of two conjunctions", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter(
                        ("product" == .string(PerfSchema.products[0]) && "quantity" > 10)
                            || ("status" == "refunded" && "total" > 2_000)
                    )
                    .take(50)
            },
            PerfScenario("Queries", "exclude, client-side negation", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .exclude("status", .equals, .string("refunded"))
                    .take(100)
            },
            PerfScenario("Queries", "count(), covered by a view", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .count()
            },
            PerfScenario("Queries", "count() over a named domain", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("quantity", .greaterThan, .int(15))
                    .count()
            },
            PerfScenario("Queries", "sum(total) over a product", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .sum("total")
            },
            PerfScenario("Queries", "maximum(total) from an exact view", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .max("total")
            },
            PerfScenario("Queries", "sum(total) by product", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).sum("total", by: "product")
            },
            PerfScenario("Queries", "count(by: status)", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).count(by: "status")
            },
            PerfScenario("Queries", "first() of a sorted query", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("status", .equals, .string("shipped"))
                    .sort("date", .descending)
                    .first()
            },
        ]
    }
}
