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
    static var migrations: [PerfScenario] {
        [
            PerfScenario(
                "Migrations", "backfill a new version", sql: 1, iterations: 1,
                setUp: { world in
                    try await publishItemVersion(
                        world, field: FieldDefinition(name: "discount", type: .double, storage: .slot(.double, "d_01"), since: 2))
                }
            ) { world, _ in
                _ = try await world.migrator.backfill(entity: PerfSchema.item) { record in
                    record.values["discount"] = .double(0)
                }
            },
            PerfScenario(
                "Migrations", "backfill against the previous record", sql: 1, iterations: 1,
                setUp: { world in
                    try await publishItemVersion(world, field: FieldDefinition(name: "was", type: .double, storage: .slot(.double, "d_01"), since: 2))
                }
            ) { world, _ in
                _ = try await world.migrator.backfill(entity: PerfSchema.item) { record, previous in
                    record.values["was"] = previous.values["price"]
                }
            },
            PerfScenario(
                "Migrations", "rename a field's data", sql: 1, iterations: 1,
                setUp: { world in
                    try await publishItemVersion(world, field: FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_02"), since: 2))
                }
            ) { world, _ in
                _ = try await world.migrator.rename(entity: PerfSchema.item, from: "sku", to: "code")
            },
            PerfScenario("Migrations", "backfill the enforced-key claims", sql: 1, iterations: 1) { world, _ in
                _ = try await world.migrator.backfillClaims(entity: PerfSchema.customer)
            },
            PerfScenario("Migrations", "rebuild one view's grid", sql: 1, iterations: 1) { world, _ in
                _ = try await world.migrator.backfill(view: "revenue", entity: PerfSchema.order)
            },
        ]
    }

    private static func publishItemVersion(_ world: PerfWorld, field: FieldDefinition) async throws {
        var fields = PerfSchema.itemDefinition.fields
        fields.append(field)
        try await world.registry.publish(EntityDefinition(entity: PerfSchema.item, version: 2, fields: fields))
    }
}
