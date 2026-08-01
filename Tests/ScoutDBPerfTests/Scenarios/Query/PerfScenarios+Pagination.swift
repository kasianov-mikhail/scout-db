//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var pagination: [PerfScenario] {
        [
            PerfScenario("Pagination", "one field page of 100 by total", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).sort("total", .descending).page(size: 100)
            },
            PerfScenario("Pagination", "walk 500 records by total", sql: 5, writes: false, iterations: 2) { world, _ in
                var cursor: FieldCursor?
                var seen = 0
                repeat {
                    let page = try await world.store.query(PerfSchema.order).sort("total").page(size: 100, after: cursor)
                    seen += page.records.count
                    cursor = page.cursor
                } while cursor != nil && seen < 500
            },
        ]
    }
}
