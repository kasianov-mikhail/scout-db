//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var writes: [PerfScenario] {
        [
            PerfScenario("Records", "write one order", sql: 1) { world, iteration in
                try await world.store.write(
                    world.newOrder(iteration),
                    entity: PerfSchema.order,
                    uuid: world.fresh("ord", iteration)
                )
            },
            PerfScenario("Records", "write one item, no views", sql: 1) { world, iteration in
                try await world.store.write(
                    [
                        "order": .string(world.order(iteration)),
                        "sku": .string(world.hotProduct),
                        "quantity": .int(2),
                        "price": .double(9.99),
                        "added": .date(world.corpus.now),
                    ],
                    entity: PerfSchema.item,
                    uuid: world.fresh("itm", iteration)
                )
            },
            PerfScenario("Records", "batch of 400 items, one chunk", sql: 1, iterations: 2) { world, iteration in
                try await world.store.write(itemBatch(world, iteration, count: 400), entity: PerfSchema.item)
            },
            PerfScenario("Records", "batch of 401 items, two chunks", sql: 1, iterations: 2) { world, iteration in
                try await world.store.write(itemBatch(world, iteration, count: 401), entity: PerfSchema.item)
            },
            PerfScenario("Records", "read one record by uuid", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.order, uuids: [world.order(iteration)])
            },
            PerfScenario("Records", "fetch 100 uuids", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.order, uuids: world.orders(100, from: iteration))
            },
            PerfScenario("Records", "fetch 500 uuids", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.order, uuids: world.orders(500, from: iteration))
            },
            PerfScenario("Records", "fetch by uuid, entity unknown", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.fetch(uuid: world.order(iteration))
            },
            PerfScenario("Records", "update one record under CAS", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.order(iteration)) { record in
                    record.values["status"] = .string("shipped")
                }
            },
            PerfScenario("Records", "update 50 records under CAS", sql: 2, iterations: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuids: world.orders(50, from: iteration)) {
                    record in
                    record.values["status"] = .string("paid")
                }
            },
            PerfScenario("Records", "delete one order", sql: 1) { world, iteration in
                try await world.store.delete(entity: PerfSchema.order, uuid: world.order(iteration))
            },
        ]
    }

    private static func itemBatch(_ world: PerfWorld, _ iteration: Int, count: Int) -> [EntityWrite] {
        (0..<count).map { index in
            let quantity = Int64(1 + index % 5)
            let price = Double(index % 200) + 0.99
            let added = world.corpus.now.addingTimeInterval(-Double(index) * 60)
            let values: [String: RecordValue] = [
                "order": .string(world.order(iteration &+ index)),
                "sku": .string(PerfSchema.products[index % PerfSchema.products.count]),
                "quantity": .int(quantity),
                "price": .double(price),
                "added": .date(added),
            ]
            return EntityWrite(values: values, uuid: world.fresh("b\(index)", iteration))
        }
    }
}
