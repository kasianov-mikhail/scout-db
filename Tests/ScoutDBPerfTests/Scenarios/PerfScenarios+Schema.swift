//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

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
            PerfScenario("Schema", "load every definition", sql: 1, writes: false) { world, _ in
                let registry = SchemaRegistry(database: world.database)
                try await registry.loadAll()
            },
            PerfScenario("Schema", "publish a new entity", sql: 1) { world, iteration in
                let entity = world.fresh("ent", iteration)
                try await world.registry.publish(
                    EntityDefinition(
                        entity: entity, version: 1,
                        fields: [
                            FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"), required: true),
                            FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                        ]))
            },
            PerfScenario("Schema", "publish a second version", sql: 1, setUp: { world in try await stageEntities(world, prefix: "ver") }) {
                world, iteration in
                try await world.registry.publish(
                    EntityDefinition(entity: world.stage.entities[iteration], version: 2, fields: fields(at: 2)))
            },
            PerfScenario("Schema", "retire an entity", sql: 1, setUp: { world in try await stageEntities(world, prefix: "ret") }) { world, iteration in
                try await world.registry.retire(entity: world.stage.entities[iteration])
            },
        ]
    }

    private static func stageEntities(_ world: PerfWorld, prefix: String) async throws {
        for iteration in 0..<world.repeats {
            let entity = world.fresh(prefix, iteration)
            try await world.registry.publish(EntityDefinition(entity: entity, version: 1, fields: fields(at: 1)))
            world.stage.entities.append(entity)
        }
    }

    private static func fields(at version: Int) -> [FieldDefinition] {
        var fields = [
            FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"), required: true),
            FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
        ]
        if version == 2 {
            fields.append(FieldDefinition(name: "score", type: .int, storage: .slot(.int, "i_00"), since: 2))
        }
        return fields
    }
}
