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
            PerfScenario("Pagination", "one envelope page of 100", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).paginate(size: 100)
            },
            PerfScenario("Pagination", "one field page of 100 by total", sql: 1, writes: false) { world, _ in
                _ = try await world.store.query(PerfSchema.order).sort("total", .descending).page(size: 100)
            },
            PerfScenario("Pagination", "stream 500 records", sql: 5, cost: .result, writes: false, iterations: 2) { world, _ in
                var seen = 0
                for try await _ in world.store.query(PerfSchema.order).stream(pageSize: 100) {
                    seen += 1
                    if seen == 500 { return }
                }
            },
        ]
    }
}
