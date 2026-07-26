//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var schema: [PerfScenario] {
        [
            PerfScenario("Schema", "definition, cold registry", sql: 1, writes: false) { world, _ in
                let registry = SchemaRegistry(database: world.database)
                _ = try await registry.definition(for: PerfSchema.order)
            },
            PerfScenario("Schema", "definition, warm registry", sql: 0, writes: false) { world, _ in
                _ = try await world.registry.definition(for: PerfSchema.order)
            },
            PerfScenario("Schema", "preload every definition", sql: 1, writes: false) { world, _ in
                let registry = SchemaRegistry(database: world.database)
                try await registry.preload()
            },
            PerfScenario("Schema", "publish a new entity", sql: 1) { world, iteration in
                let entity = world.fresh("ent", iteration)
                try await world.registry.publish(
                    EntityDefinition(
                        entity: entity, version: 1,
                        fields: [
                            FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"), required: true),
                            FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                        ], envelopeDate: "at"))
            },
            PerfScenario("Schema", "publish a second version", sql: 2) { world, iteration in
                let entity = world.fresh("ver", iteration)
                for version in 1...2 {
                    var fields = [
                        FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"), required: true),
                        FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                    ]
                    if version == 2 {
                        fields.append(FieldDefinition(name: "score", type: .int, storage: .slot(.int, "i_00"), since: 2))
                    }
                    try await world.registry.publish(EntityDefinition(entity: entity, version: version, fields: fields, envelopeDate: "at"))
                }
            },
            PerfScenario("Schema", "retire an entity", sql: 1) { world, iteration in
                let entity = world.fresh("ret", iteration)
                try await world.registry.publish(
                    EntityDefinition(
                        entity: entity, version: 1,
                        fields: [FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true)], envelopeDate: "at"))
                try await world.registry.retire(entity: entity)
            },
        ]
    }
}
