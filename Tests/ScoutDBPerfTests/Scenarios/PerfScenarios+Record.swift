//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var relations: [PerfScenario] {
        [
            PerfScenario(
                "Relations", "join customers of 100 orders", sql: 1, writes: false,
                setUp: { world in
                    world.stage.records = try await world.store.fetch(entity: PerfSchema.order, uuids: world.orders(100, from: 0))
                }
            ) { world, _ in
                _ = try await world.store.join(entity: PerfSchema.order, records: world.stage.records, field: "customer")
            },
            PerfScenario(
                "Relations", "join two hops, item to customer", sql: 1, writes: false,
                setUp: { world in
                    world.stage.records = try await world.store.fetch(entity: PerfSchema.item, uuids: (0..<50).map { world.item($0) })
                }
            ) { world, _ in
                _ = try await world.store.join(entity: PerfSchema.item, records: world.stage.records, path: ["order", "customer"])
            },
            PerfScenario("Relations", "children of one customer", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.children(entity: PerfSchema.order, of: world.customer(iteration), via: "customer")
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
            PerfScenario(
                "Revisions", "history of a record", sql: 1, writes: false,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let uuid = world.session(iteration)
                        for step in 0..<3 {
                            try await world.store.update(entity: PerfSchema.session, uuid: uuid) { record in
                                record.values["seconds"] = .int(Int64(step))
                            }
                        }
                        world.stage.uuids.append(uuid)
                    }
                }
            ) { world, iteration in
                _ = try await world.store.history(entity: PerfSchema.session, uuid: world.stage.uuids[iteration])
            },
            PerfScenario("Revisions", "compact the revision log", sql: 1, iterations: 2) { world, _ in
                _ = try await world.store.compactRevisions(olderThan: Date().addingTimeInterval(60))
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
            PerfScenario(
                "Assets", "read the asset bytes back", sql: 1, writes: false,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let uuid = world.fresh("read", iteration)
                        try await world.store.write(
                            [
                                "name": .string("Avatar \(iteration)"),
                                "email": .string("\(world.runID)-read-\(iteration)@example.com"),
                                "country": .string("fr"),
                                "signup": .date(world.corpus.now),
                                "avatar": .bytes(Data(repeating: UInt8(128 + iteration % 100), count: 32 * 1_024)),
                            ], entity: PerfSchema.customer, uuid: uuid)
                        world.stage.uuids.append(uuid)
                    }
                }
            ) { world, iteration in
                let record = try await world.store.fetch(entity: PerfSchema.customer, uuids: [world.stage.uuids[iteration]]).first
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
            PerfScenario(
                "Encryption", "read a sealed field back", sql: 1, writes: false,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let uuid = world.fresh("open", iteration)
                        try await world.store.write(
                            [
                                "customer": .string(world.customer(iteration)),
                                "device": .string("watch"),
                                "started": .date(world.corpus.now),
                                "token": .string("secret-\(iteration)"),
                            ], entity: PerfSchema.session, uuid: uuid)
                        world.stage.uuids.append(uuid)
                    }
                }
            ) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.session, uuids: [world.stage.uuids[iteration]])
            },
        ]
    }
}
