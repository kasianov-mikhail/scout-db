//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var pagination: [PerfScenario] {
        [
            PerfScenario("Pagination", "five envelope pages of 100", sql: 5, writes: false, iterations: 2) { world, _ in
                var cursor: EntityCursor?
                for _ in 0..<5 {
                    let page = try await world.store.query(PerfSchema.order).paginate(size: 100, after: cursor)
                    guard let next = page.cursor else { return }
                    cursor = next
                }
            },
            PerfScenario("Pagination", "five field pages of 100 by total", sql: 5, writes: false, iterations: 2) { world, _ in
                var cursor: FieldCursor?
                for _ in 0..<5 {
                    let page = try await world.store.query(PerfSchema.order).sort("total", .descending).page(size: 100, after: cursor)
                    guard let next = page.cursor else { return }
                    cursor = next
                }
            },
            PerfScenario("Pagination", "filtered pages of 50", sql: 5, writes: false, iterations: 2) { world, _ in
                var cursor: EntityCursor?
                for _ in 0..<5 {
                    let page = try await world.store.query(PerfSchema.order)
                        .filter("status", .equals, .string("paid"))
                        .paginate(size: 50, after: cursor)
                    guard let next = page.cursor else { return }
                    cursor = next
                }
            },
            PerfScenario("Pagination", "stream 500 records", sql: 5, writes: false, iterations: 2) { world, _ in
                var seen = 0
                for try await _ in world.store.query(PerfSchema.order).stream(pageSize: 100) {
                    seen += 1
                    if seen == 500 { return }
                }
            },
            PerfScenario("Pagination", "stream 2000 records, 500 a page", sql: 4, writes: false, iterations: 2) { world, _ in
                var seen = 0
                for try await _ in world.store.query(PerfSchema.order).stream(pageSize: 500) {
                    seen += 1
                    if seen == 2_000 { return }
                }
            },
        ]
    }
}
