//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

extension PerfScenarios {
    static var migrations: [PerfScenario] {
        [
            PerfScenario("Migrations", "backfill a new version", sql: 2, cost: .elective, iterations: 1) { world, _ in
                try await publishItemVersion(world, field: FieldDefinition(name: "discount", type: .double, storage: .slot(.double, "d_01"), since: 2))
                _ = try await world.migrator.backfill(entity: PerfSchema.item) { record in
                    record.values["discount"] = .double(0)
                }
            },
            PerfScenario("Migrations", "rename a field's data", sql: 1, cost: .elective, iterations: 1) { world, _ in
                try await publishItemVersion(world, field: FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_02"), since: 2))
                _ = try await world.migrator.rename(entity: PerfSchema.item, from: "sku", to: "code")
            },
            PerfScenario("Migrations", "backfill the enforced-key claims", sql: 1, cost: .elective, iterations: 1) { world, _ in
                _ = try await world.migrator.backfillClaims(entity: PerfSchema.customer)
            },
            PerfScenario("Migrations", "rebuild one view's grid", sql: 1, cost: .elective, iterations: 1) { world, _ in
                _ = try await world.migrator.backfill(view: "revenue", entity: PerfSchema.order)
            },
            PerfScenario("Migrations", "rotate the encryption key", sql: 1, cost: .elective, iterations: 1) { world, _ in
                _ = try await world.migrator.rotateKey(entity: PerfSchema.session, to: "perf-key-2")
            },
        ]
    }

    private static func publishItemVersion(_ world: PerfWorld, field: FieldDefinition) async throws {
        var fields = PerfSchema.itemDefinition.fields
        fields.append(field)
        try await world.registry.publish(EntityDefinition(entity: PerfSchema.item, version: 2, fields: fields, envelopeDate: "added"))
    }
}
