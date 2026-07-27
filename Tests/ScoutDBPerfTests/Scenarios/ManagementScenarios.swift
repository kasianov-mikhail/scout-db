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

    static var porting: [PerfScenario] {
        [
            PerfScenario("Porting", "export one entity", sql: 1, cost: .result, writes: false, iterations: 2) { world, _ in
                _ = try await world.store.export(entity: PerfSchema.item)
            },
            PerfScenario("Porting", "import 100 records", sql: 1, cost: .result, iterations: 2) { world, iteration in
                let records = (0..<100).map { index in
                    EntityRecord(
                        entity: PerfSchema.item, uuid: world.fresh("imp\(index)", iteration), schemaVersion: 1,
                        values: [
                            "order": .string(world.order(index)),
                            "sku": .string(PerfSchema.products[index % PerfSchema.products.count]),
                            "quantity": .int(1),
                            "price": .double(1.99),
                            "added": .date(world.corpus.now),
                        ])
                }
                _ = try await world.store.importRecords(try JSONEncoder().encode(records), entity: PerfSchema.item)
            },
        ]
    }

    static var sharing: [PerfScenario] {
        [
            PerfScenario("Sharing", "share the zone", sql: 1) { world, _ in
                _ = try await world.store.shareZone(title: "Perf")
            },
            PerfScenario("Sharing", "share one record", sql: 1) { world, iteration in
                _ = try await world.store.shareRecord(entity: PerfSchema.order, uuid: world.order(iteration))
            },
            PerfScenario("Sharing", "read the zone share's participants", sql: 1) { world, _ in
                _ = try await world.store.shareZone()
                _ = try await world.store.shareParticipants()
            },
            PerfScenario("Sharing", "stop sharing the zone", sql: 1) { world, _ in
                _ = try await world.store.shareZone()
                try await world.store.stopSharing()
            },
        ]
    }

    private static func publishItemVersion(_ world: PerfWorld, field: FieldDefinition) async throws {
        var fields = PerfSchema.itemDefinition.fields
        fields.append(field)
        try await world.registry.publish(EntityDefinition(entity: PerfSchema.item, version: 2, fields: fields, envelopeDate: "added"))
    }
}
