//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var relations: [PerfScenario] {
        [
            PerfScenario("Relations", "join customers of 100 orders", sql: 1, writes: false) { world, iteration in
                let orders = try await world.store.fetch(entity: PerfSchema.order, uuids: world.orders(100, from: iteration))
                _ = try await world.store.join(entity: PerfSchema.order, records: orders, field: "customer")
            },
            PerfScenario("Relations", "join two hops, item to customer", sql: 1, writes: false) { world, iteration in
                let items = try await world.store.fetch(entity: PerfSchema.item, uuids: (0..<50).map { world.item(iteration &* 50 &+ $0) })
                _ = try await world.store.join(entity: PerfSchema.item, records: items, path: ["order", "customer"])
            },
            PerfScenario("Relations", "children of one customer", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.children(entity: PerfSchema.order, of: world.customer(iteration), via: "customer")
            },
            PerfScenario("Relations", "orphans of the item entity", sql: 1, cost: .elective, writes: false) { world, _ in
                _ = try await world.store.orphans(entity: PerfSchema.item, field: "order")
            },
            PerfScenario("Relations", "delete one order, cascading", sql: 1) { world, iteration in
                try await world.store.delete(entity: PerfSchema.order, uuid: world.order(iteration), cascade: true)
            },
            PerfScenario("Relations", "delete one customer, cascading", sql: 1, iterations: 2) { world, iteration in
                try await world.store.delete(entity: PerfSchema.customer, uuid: world.customer(iteration), cascade: true)
            },
        ]
    }

    static var revisions: [PerfScenario] {
        [
            PerfScenario("Revisions", "update an audited record", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.session, uuid: world.session(iteration)) { record in
                    record.values["seconds"] = .int(Int64(iteration &+ 1) &* 60)
                }
            },
            PerfScenario("Revisions", "history of a record", sql: 7) { world, iteration in
                let uuid = world.session(iteration)
                for step in 0..<3 {
                    try await world.store.update(entity: PerfSchema.session, uuid: uuid) { record in
                        record.values["seconds"] = .int(Int64(step))
                    }
                }
                _ = try await world.store.history(entity: PerfSchema.session, uuid: uuid)
            },
            PerfScenario("Revisions", "compact the revision log", sql: 1, iterations: 2) { world, _ in
                _ = try await world.store.compactRevisions(olderThan: Date().addingTimeInterval(60))
            },
        ]
    }

    static var lifecycle: [PerfScenario] {
        [
            PerfScenario("Lifecycle", "restore a tombstoned record", sql: 1) { world, iteration in
                _ = try await world.store.restore(entity: PerfSchema.session, uuid: world.tombstoned(iteration))
            },
            PerfScenario("Lifecycle", "compact tombstones", sql: 1, iterations: 2) { world, _ in
                _ = try await world.store.compact(entity: PerfSchema.session, olderThan: Date().addingTimeInterval(60))
            },
            PerfScenario("Lifecycle", "reap the expired sessions", sql: 1, cost: .answer, iterations: 2) { world, _ in
                _ = try await world.store.reap(entity: PerfSchema.session, asOf: world.corpus.now)
            },
            PerfScenario("Lifecycle", "drop an entity", sql: 3, iterations: 1) { world, iteration in
                let entity = world.fresh("drp", iteration)
                try await world.registry.publish(
                    EntityDefinition(
                        entity: entity, version: 1,
                        fields: [
                            FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_00"), required: true),
                            FieldDefinition(name: "at", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                        ], envelopeDate: "at"))
                let batch = (0..<50).map { index in
                    EntityWrite(values: ["label": .string("l\(index)"), "at": .date(world.corpus.now)], uuid: "\(entity)-\(index)")
                }
                try await world.store.write(batch, entity: entity)
                _ = try await world.store.drop(entity: entity)
            },
        ]
    }

    static var assets: [PerfScenario] {
        [
            PerfScenario("Assets", "write a record carrying an asset", sql: 1) { world, iteration in
                try await world.store.write(
                    [
                        "name": .string("Avatar \(iteration)"),
                        "email": .string("\(world.runID)-asset-\(iteration)@example.com"),
                        "country": .string("de"),
                        "signup": .date(world.corpus.now),
                        "avatar": .bytes(Data(repeating: UInt8(iteration % 251), count: 64 * 1_024)),
                    ], entity: PerfSchema.customer, uuid: world.fresh("ava", iteration))
            },
            PerfScenario("Assets", "read the asset bytes back", sql: 2) { world, iteration in
                let uuid = world.fresh("read", iteration)
                try await world.store.write(
                    [
                        "name": .string("Avatar \(iteration)"),
                        "email": .string("\(world.runID)-read-\(iteration)@example.com"),
                        "country": .string("fr"),
                        "signup": .date(world.corpus.now),
                        "avatar": .bytes(Data(repeating: UInt8(128 + iteration % 100), count: 32 * 1_024)),
                    ], entity: PerfSchema.customer, uuid: uuid)
                let record = try await world.store.fetch(entity: PerfSchema.customer, uuids: [uuid]).first
                _ = try record?.assetData(for: "avatar")
            },
        ]
    }

    static var encryption: [PerfScenario] {
        [
            PerfScenario("Encryption", "write a sealed field", sql: 1) { world, iteration in
                try await world.store.write(
                    [
                        "customer": .string(world.customer(iteration)),
                        "device": .string("mac"),
                        "started": .date(world.corpus.now),
                        "token": .string("secret-\(iteration)"),
                    ], entity: PerfSchema.session, uuid: world.fresh("sec", iteration))
            },
            PerfScenario("Encryption", "read a sealed field back", sql: 2) { world, iteration in
                let uuid = world.fresh("open", iteration)
                try await world.store.write(
                    [
                        "customer": .string(world.customer(iteration)),
                        "device": .string("watch"),
                        "started": .date(world.corpus.now),
                        "token": .string("secret-\(iteration)"),
                    ], entity: PerfSchema.session, uuid: uuid)
                _ = try await world.store.fetch(entity: PerfSchema.session, uuids: [uuid])
            },
        ]
    }
}
