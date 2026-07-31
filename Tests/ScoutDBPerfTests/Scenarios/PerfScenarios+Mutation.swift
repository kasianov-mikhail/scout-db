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
    static var uniqueKeys: [PerfScenario] {
        [
            PerfScenario("Unique keys", "write a customer, one fresh claim", sql: 1) { world, iteration in
                try await world.store.write(newCustomer(world, iteration), entity: PerfSchema.customer, uuid: world.fresh("cus", iteration))
            },
            PerfScenario(
                "Unique keys", "rewrite, claim already held", sql: 1,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let uuid = world.fresh("keep", iteration)
                        try await world.store.write(newCustomer(world, iteration), entity: PerfSchema.customer, uuid: uuid)
                        world.stage.uuids.append(uuid)
                    }
                }
            ) { world, iteration in
                var values = newCustomer(world, iteration)
                values["points"] = .double(1)
                try await world.store.write(values, entity: PerfSchema.customer, uuid: world.stage.uuids[iteration])
            },
            PerfScenario("Unique keys", "write into a taken email", sql: 1) { world, iteration in
                var values = newCustomer(world, iteration)
                values["email"] = .string("user0@example.com")
                do {
                    try await world.store.write(values, entity: PerfSchema.customer, uuid: world.fresh("dup", iteration))
                } catch is SchemaError {
                    return
                }
            },
        ]
    }

    static var conflicts: [PerfScenario] {
        [
            PerfScenario("Conflicts", "every iteration updates one record", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.corpus.orders[0], maxRetry: 16) { record in
                    record.values["note"] = .string("note-\(iteration)")
                }
            }
        ]
    }

    private static func newCustomer(_ world: PerfWorld, _ iteration: Int) -> [String: RecordValue] {
        [
            "name": .string("Fresh \(iteration)"),
            "email": .string("\(world.runID)-\(iteration)@example.com"),
            "country": .string(PerfSchema.countries[iteration % PerfSchema.countries.count]),
            "signup": .date(world.corpus.now),
            "points": .double(0),
            "tags": .strings(["photo"]),
        ]
    }
}
