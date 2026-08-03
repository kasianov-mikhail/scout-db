//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Aggregate deltas")
struct AggregateDeltasTests {
    private func payment(_ uuid: String, product: String = "app", amount: Double? = 1) -> EntityRecord {
        var values: [String: RecordValue] = ["product": .string(product)]
        if let amount {
            values["amount"] = .double(amount)
        }
        return EntityRecord(entity: "payment", uuid: uuid, schemaVersion: 2, values: values)
    }

    private func slot(_ aggregate: String, group: String = "", shard: Int? = nil) -> GridSlot {
        GridSlot(entity: "payment", aggregate: aggregate, group: group, shard: shard)
    }

    @Test("Records sharing a group fold into one slot, and each aggregate keeps its own")
    func groupsFoldPerAggregate() throws {
        let aggregates = [
            AggregateDefinition(name: "by_product", groupBy: "product"),
            AggregateDefinition(name: "revenue", groupBy: "product", sum: "amount"),
        ]

        let deltas = aggregates.deltas(
            removing: [],
            adding: [payment("p-0", amount: 2), payment("p-1", amount: 3), payment("p-2", product: "pro")]
        )

        #expect(deltas.count == 4)

        let counted = try #require(deltas[slot("by_product", group: "app")])
        #expect(counted.count == 2)
        #expect(counted.total == nil)

        let summed = try #require(deltas[slot("revenue", group: "app")])
        #expect(summed.count == 2)
        #expect(summed.total?.kind == .sum)
        #expect(summed.total?.value == 5)
    }

    @Test("A removal reverses a sum aggregate")
    func removalReversesASum() throws {
        let aggregates = [AggregateDefinition(name: "revenue", sum: "amount")]

        let deltas = aggregates.deltas(removing: [payment("p-0", amount: 5)], adding: [])

        let delta = try #require(deltas[slot("revenue")])
        #expect(delta.count == -1)
        #expect(delta.total?.value == -5)
    }

    @Test("A removal moves a min aggregate's count without touching its value")
    func removalHoldsAMinValue() throws {
        let aggregates = [AggregateDefinition(name: "cheapest", min: "amount")]

        let deltas = aggregates.deltas(removing: [payment("p-0", amount: 5)], adding: [])

        let delta = try #require(deltas[slot("cheapest")])
        #expect(delta.count == -1)
        #expect(delta.total == nil)
    }

    @Test("A record rewritten unchanged plans nothing for a sum aggregate")
    func unchangedRewritePlansNothing() {
        let aggregates = [AggregateDefinition(name: "revenue", sum: "amount")]
        let stored = payment("p-0", amount: 5)

        #expect(aggregates.deltas(removing: [stored], adding: [stored]).isEmpty)
    }

    @Test("A record rewritten unchanged still plans a write for a min aggregate")
    func unchangedRewriteStillPlansAMin() throws {
        let aggregates = [AggregateDefinition(name: "cheapest", min: "amount")]
        let stored = payment("p-0", amount: 5)

        let deltas = aggregates.deltas(removing: [stored], adding: [stored])

        let delta = try #require(deltas[slot("cheapest")])
        #expect(delta.count == 0)
        #expect(delta.total?.value == 5)
    }

    @Test("A record missing the metric field moves only the count")
    func missingMetricFieldMovesTheCount() throws {
        let aggregates = [AggregateDefinition(name: "revenue", sum: "amount")]

        let deltas = aggregates.deltas(removing: [], adding: [payment("p-0", amount: nil)])

        let delta = try #require(deltas[slot("revenue")])
        #expect(delta.count == 1)
        #expect(delta.total == nil)
    }

    @Test("Shards spread one group over slots without losing a record")
    func shardsSpreadTheGroup() {
        let aggregates = [AggregateDefinition(name: "by_all", shards: 4)]
        let batch = (0..<20).map { payment("p-\($0)") }

        let deltas = aggregates.deltas(removing: [], adding: batch)

        #expect(deltas.count > 1)
        #expect(deltas.keys.allSatisfy { ($0.shard ?? 0) < 4 })
        #expect(deltas.values.reduce(0) { $0 + $1.count } == 20)
    }

    @Test("A shard follows the record's uuid, so a rewrite lands on the slot it left")
    func shardFollowsTheUUID() {
        let aggregates = [AggregateDefinition(name: "by_all", shards: 4)]

        let deltas = aggregates.deltas(removing: [payment("p-7", amount: 2)], adding: [payment("p-7", amount: 9)])

        #expect(deltas.isEmpty)
    }
}
