//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var conflicts: [PerfScenario] {
        [
            PerfScenario("Conflicts", "every iteration updates one record", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.corpus.orders[0], maxRetry: 16) {
                    record in
                    record.values["note"] = .string("note-\(iteration)")
                }
            }
        ]
    }
}
