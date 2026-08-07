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
    private let noon = Date(timeIntervalSince1970: 36_000)
    private let nextWeek = Date(timeIntervalSince1970: 36_000 + 7 * 86_400)

    private func payment(
        _ uuid: String,
        product: String = "app",
        amount: Double? = 1,
        date: Date? = nil
    ) -> EntityRecord {
        var values: [String: RecordValue] = ["product": .string(product)]
        if let amount {
            values["amount"] = .double(amount)
        }
        if let date {
            values["date"] = .date(date)
        }
        return EntityRecord(entity: "payment", uuid: uuid, schemaVersion: 2, values: values)
    }

    private func slot<Holder: Vector>(
        _ holder: Holder.Type, _ aggregate: String, group: String = "", shard: Int? = nil, week: Date? = nil
    ) -> VectorSlot<Holder> {
        VectorSlot(
            entity: "payment",
            aggregate: aggregate,
            group: group,
            shard: shard,
            week: (week ?? noon).weekStart
        )
    }

    @Test("Records sharing a group and an hour fold into one cell, and each aggregate keeps its own")
    func groupsFoldPerAggregate() throws {
        let aggregates = [
            AggregateDefinition(group: "product"),
            AggregateDefinition(metric: .sum, field: "amount", group: "product"),
        ]

        let deltas = aggregates.deltas(
            removing: [],
            adding: [payment("p-0", amount: 2), payment("p-1", amount: 3), payment("p-2", product: "pro")],
            at: noon
        )

        #expect(deltas.counts.count == 2)
        #expect(deltas.measures.count == 2)

        let counted = try #require(deltas.counts[slot(IntVector.self, "by_product", group: "app")])
        #expect(counted.cells == [noon.hourOfWeek: 2])

        let summed = try #require(deltas.measures[slot(DoubleVector.self, "sum_amount_by_product", group: "app")])
        #expect(summed.kind == .sum)
        #expect(summed.cells == [noon.hourOfWeek: 5])
    }

    @Test("An aggregate dating its cells reads the hour off the record, not off the write")
    func declaredDateAddressesTheCell() throws {
        let aggregates = [AggregateDefinition(date: "date")]
        let stamped = Date(timeIntervalSince1970: 1_785_937_500)

        let deltas = aggregates.deltas(removing: [], adding: [payment("p-0", date: stamped)], at: noon)

        let delta = try #require(deltas.counts[slot(IntVector.self, "at_date", week: stamped)])
        #expect(delta.cells == [stamped.hourOfWeek: 1])
    }

    @Test("A record without the dated field falls back to the hour of the write")
    func missingDateFallsBackToTheWrite() throws {
        let aggregates = [AggregateDefinition(date: "date")]

        let deltas = aggregates.deltas(removing: [], adding: [payment("p-0")], at: noon)

        let delta = try #require(deltas.counts[slot(IntVector.self, "at_date")])
        #expect(delta.cells == [noon.hourOfWeek: 1])
    }

    @Test("Records of two weeks fold into a slot each")
    func weeksFoldApart() throws {
        let aggregates = [AggregateDefinition(date: "date")]

        let deltas = aggregates.deltas(
            removing: [],
            adding: [payment("p-0", date: noon), payment("p-1", date: nextWeek)],
            at: noon
        )

        #expect(deltas.counts.count == 2)
        #expect(deltas.counts[slot(IntVector.self, "at_date")]?.cells == [noon.hourOfWeek: 1])
        #expect(deltas.counts[slot(IntVector.self, "at_date", week: nextWeek)]?.cells == [nextWeek.hourOfWeek: 1])
    }

    @Test("A removal reverses a sum aggregate")
    func removalReversesASum() throws {
        let aggregates = [AggregateDefinition(metric: .sum, field: "amount")]

        let deltas = aggregates.deltas(removing: [payment("p-0", amount: 5)], adding: [], at: noon)

        let delta = try #require(deltas.measures[slot(DoubleVector.self, "sum_amount")])
        #expect(delta.cells == [noon.hourOfWeek: -5])
    }

    @Test("A removal plans nothing for a min aggregate, whose value stands")
    func removalHoldsAMinValue() {
        let aggregates = [AggregateDefinition(metric: .min, field: "amount")]

        #expect(aggregates.deltas(removing: [payment("p-0", amount: 5)], adding: [], at: noon).isEmpty)
    }

    @Test("A record rewritten unchanged plans nothing for a sum aggregate")
    func unchangedRewritePlansNothing() {
        let aggregates = [AggregateDefinition(metric: .sum, field: "amount")]
        let stored = payment("p-0", amount: 5)

        #expect(aggregates.deltas(removing: [stored], adding: [stored], at: noon).isEmpty)
    }

    @Test("A record rewritten unchanged still plans a write for a min aggregate")
    func unchangedRewriteStillPlansAMin() throws {
        let aggregates = [AggregateDefinition(metric: .min, field: "amount")]
        let stored = payment("p-0", amount: 5)

        let deltas = aggregates.deltas(removing: [stored], adding: [stored], at: noon)

        let delta = try #require(deltas.measures[slot(DoubleVector.self, "min_amount")])
        #expect(delta.cells == [noon.hourOfWeek: 5])
    }

    @Test("A record missing the metric field is folded into no cell of it")
    func missingMetricFieldFoldsNowhere() {
        let aggregates = [AggregateDefinition(metric: .sum, field: "amount")]

        #expect(aggregates.deltas(removing: [], adding: [payment("p-0", amount: nil)], at: noon).isEmpty)
    }

    @Test("Shards spread one group over slots without losing a record")
    func shardsSpreadTheGroup() {
        let aggregates = [AggregateDefinition(shards: 4)]
        let batch = (0..<20).map { payment("p-\($0)") }

        let deltas = aggregates.deltas(removing: [], adding: batch, at: noon)

        #expect(deltas.counts.count > 1)
        #expect(deltas.counts.keys.allSatisfy { ($0.shard ?? 0) < 4 })

        let folded = deltas.counts.values.reduce(Int64(0)) { $0 + $1.cells.values.reduce(0, +) }
        #expect(folded == 20)
    }

    @Test("A histogram counts its bucket, and lands among the counters")
    func histogramCountsItsBucket() throws {
        let histogram = AggregateDefinition.Histogram(field: "amount", bounds: [1, 10])
        let aggregates = [AggregateDefinition(histogram: histogram.field, bounds: histogram.bounds)]

        let deltas = aggregates.deltas(removing: [], adding: [payment("p-0", amount: 5)], at: noon)

        #expect(deltas.measures.isEmpty)

        let bucket = histogram.groupKey(of: 5)
        let delta = try #require(deltas.counts[slot(IntVector.self, "histogram_amount", group: bucket)])
        #expect(delta.cells == [noon.hourOfWeek: 1])
    }

    @Test("A shard follows the record's uuid, so a rewrite lands on the slot it left")
    func shardFollowsTheUUID() {
        let aggregates = [AggregateDefinition(shards: 4)]

        let deltas = aggregates.deltas(
            removing: [payment("p-7", amount: 2)],
            adding: [payment("p-7", amount: 9)],
            at: noon
        )

        #expect(deltas.isEmpty)
    }
}
