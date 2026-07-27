//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var queries: [PerfScenario] {
        [
            PerfScenario("Queries", "all(), one product, unbounded", sql: 1, cost: .answer, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .all()
            },
            PerfScenario("Queries", "filter + sort + limit 20", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("status", .equals, .string("paid"))
                    .sort("total", .descending)
                    .limit(20)
                    .all()
            },
            PerfScenario("Queries", "OR group of three products, limit 50", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .group {
                        $0.filter("product", .equals, .string(PerfSchema.products[0]))
                        $0.filter("product", .equals, .string(PerfSchema.products[1]))
                        $0.filter("product", .equals, .string(PerfSchema.products[2]))
                    }
                    .limit(50)
                    .all()
            },
            PerfScenario("Queries", "OR of two conjunctions", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .group {
                        $0.all(
                            EntityStore.Filter(field: "product", op: .equals, value: .string(PerfSchema.products[0])),
                            EntityStore.Filter(field: "quantity", op: .greaterThan, value: .int(10)))
                        $0.all(
                            EntityStore.Filter(field: "status", op: .equals, value: .string("refunded")),
                            EntityStore.Filter(field: "total", op: .greaterThan, value: .double(2_000)))
                    }
                    .limit(50)
                    .all()
            },
            PerfScenario("Queries", "exclude, client-side negation", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .exclude("status", .equals, .string("refunded"))
                    .limit(100)
                    .all()
            },
            PerfScenario("Queries", "count(), covered by a view", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .count()
            },
            PerfScenario("Queries", "count(), scanning", sql: 1, cost: .elective, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("quantity", .greaterThan, .int(15))
                    .count()
            },
            PerfScenario("Queries", "sum(total) over a product", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .sum("total")
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
            PerfScenario("Queries", "projection to two fields", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .fields("total", "date")
                    .limit(200)
                    .all()
            },
            PerfScenario("Queries", "explain the plan", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order)
                    .filter("product", .equals, .string(world.hotProduct))
                    .filter("quantity", .greaterThan, .int(2))
                    .explain()
            },
        ]
    }
}
