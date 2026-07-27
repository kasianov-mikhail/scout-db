//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

extension PerfScenarios {
    static var counters: [PerfScenario] {
        [
            PerfScenario("Counters", "increment a customer's points", sql: 1) { world, iteration in
                try await world.store.increment(entity: PerfSchema.customer, uuid: world.customer(iteration), field: "points", by: 10)
            },
            PerfScenario("Counters", "increment one hot record", sql: 1) { world, _ in
                try await world.store.increment(entity: PerfSchema.customer, uuid: world.corpus.customers[0], field: "points")
            },
            PerfScenario("Counters", "insert two tags", sql: 1) { world, iteration in
                _ = try await world.store.insert(["vip", "beta"], into: "tags", entity: PerfSchema.customer, uuid: world.customer(iteration))
            },
            PerfScenario("Counters", "remove a tag", sql: 1) { world, iteration in
                _ = try await world.store.remove(["photo"], from: "tags", entity: PerfSchema.customer, uuid: world.customer(iteration))
            },
        ]
    }

    static var uniqueKeys: [PerfScenario] {
        [
            PerfScenario("Unique keys", "write a customer, one fresh claim", sql: 1) { world, iteration in
                try await world.store.write(newCustomer(world, iteration), entity: PerfSchema.customer, uuid: world.fresh("cus", iteration))
            },
            PerfScenario("Unique keys", "batch of 50 customers, 50 claims", sql: 1, cost: .result, iterations: 2) { world, iteration in
                let batch = (0..<50).map { index in
                    EntityWrite(values: newCustomer(world, iteration &* 100 &+ index), uuid: world.fresh("cb\(index)", iteration))
                }
                try await world.store.write(batch, entity: PerfSchema.customer)
            },
            PerfScenario("Unique keys", "rewrite, claim already held", sql: 2) { world, iteration in
                let uuid = world.fresh("keep", iteration)
                var values = newCustomer(world, iteration)
                try await world.store.write(values, entity: PerfSchema.customer, uuid: uuid)
                values["points"] = .double(1)
                try await world.store.write(values, entity: PerfSchema.customer, uuid: uuid)
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

    static var transactions: [PerfScenario] {
        [
            PerfScenario("Transactions", "three writes in one transaction", sql: 1, cost: .result) { world, iteration in
                try await world.store.transaction { draft in
                    for index in 0..<3 {
                        draft.write(world.newOrder(iteration, offset: index), entity: PerfSchema.order, uuid: world.fresh("tx\(index)", iteration))
                    }
                }
            },
            PerfScenario("Transactions", "a write, an update and a delete", sql: 3, cost: .result) { world, iteration in
                let uuid = world.fresh("mix", iteration)
                try await world.store.transaction { draft in
                    draft.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: uuid)
                    draft.update(["status": .string("paid")], entity: PerfSchema.order, uuid: world.order(iteration))
                    draft.delete(entity: PerfSchema.item, uuid: world.item(iteration))
                }
            },
            PerfScenario("Transactions", "repair a pending envelope", sql: 4, iterations: 2) { world, iteration in
                let steps = [TransactionStep(entity: PerfSchema.order, uuid: world.fresh("rep", iteration), values: world.newOrder(iteration))]
                try await world.store.write(
                    [
                        "status": .string("pending"),
                        "date": .date(world.corpus.now),
                        "steps": .bytes(try JSONEncoder().encode(steps)),
                    ], entity: EntityStore.transactionEntity, uuid: world.fresh("env", iteration))
                _ = try await world.store.repairTransactions()
            },
            PerfScenario("Transactions", "compact committed envelopes", sql: 2, cost: .elective, iterations: 2) { world, iteration in
                try await world.store.transaction { draft in
                    draft.write(world.newOrder(iteration), entity: PerfSchema.order, uuid: world.fresh("cmp", iteration))
                }
                _ = try await world.store.compactTransactions(olderThan: Date().addingTimeInterval(60))
            },
        ]
    }

    static var leases: [PerfScenario] {
        [
            PerfScenario("Leases", "take a lease", sql: 1) { world, iteration in
                try await world.store.lease(entity: PerfSchema.order, uuid: world.order(iteration), owner: "worker-\(iteration)", for: 60)
            },
            PerfScenario("Leases", "take, read and release", sql: 3) { world, iteration in
                let uuid = world.order(iteration)
                let owner = "worker-\(iteration)"
                try await world.store.lease(entity: PerfSchema.order, uuid: uuid, owner: owner, for: 60)
                _ = try await world.store.leaseHolder(entity: PerfSchema.order, uuid: uuid)
                try await world.store.release(entity: PerfSchema.order, uuid: uuid, owner: owner)
            },
            PerfScenario("Leases", "read a free record's holder", sql: 1, writes: false) { world, iteration in
                _ = try await world.store.leaseHolder(entity: PerfSchema.order, uuid: world.order(iteration))
            },
        ]
    }

    static var conflicts: [PerfScenario] {
        [
            PerfScenario("Conflicts", "every iteration updates one record", sql: 2) { world, iteration in
                try await world.store.update(entity: PerfSchema.order, uuid: world.corpus.orders[0], maxRetry: 16) { record in
                    record.values["note"] = .string("note-\(iteration)")
                }
            },
            PerfScenario("Conflicts", "flush a queued write through a resolver", sql: 2, stack: .offline) { world, iteration in
                guard let cache = world.offlineCache else { return }
                let uuid = world.order(iteration)
                cache.setConflictResolver(
                    world.store.conflictResolver { queued, server, _ in
                        var merged = server
                        merged.values["note"] = queued.values["note"]
                        return .save(merged)
                    })
                try await world.store.update(entity: PerfSchema.order, uuid: uuid) { record in
                    record.values["note"] = .string("queued-\(iteration)")
                }
                _ = try await cache.flush()
            },
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
