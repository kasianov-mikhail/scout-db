//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Shard plan")
struct ShardPlanTests {
    private let week = Date(timeIntervalSince1970: 36_000).weekStart
    private let other = Date(timeIntervalSince1970: 36_000 + 7 * 86_400).weekStart

    private var key: String {
        String(week.millisecondsSince1970)
    }

    private func slot(aggregate: String, group: String) -> VectorSlot {
        VectorSlot(entity: "payment", aggregate: aggregate, group: group, shard: nil, part: 0, week: week)
    }

    @Test("An undeclared, uncontended week is unsharded and reached by the bare name")
    func bareWeek() {
        #expect(ShardPlan(floor: nil).count(week: week) == nil)
    }

    @Test("The schema's count is the floor a week starts from")
    func floorHolds() {
        #expect(ShardPlan(floor: 4).count(week: week) == 4)
    }

    @Test("A week that outgrew the floor keeps the larger of the two")
    func growthOutranksTheFloor() {
        #expect(ShardPlan(floor: 4, grown: [key: 16]).count(week: week) == 16)
        #expect(ShardPlan(floor: 16, grown: [key: 4]).count(week: week) == 16)
    }

    @Test("A week that grew leaves its neighbours where they were")
    func growthIsPerWeek() {
        let plan = ShardPlan(floor: nil, grown: [key: 4])

        #expect(plan.count(week: week) == 4)
        #expect(plan.count(week: other) == nil)
    }

    @Test("A count that will not parse as a week is dropped rather than mistaken for one")
    func unparsableWeekIsDropped() {
        #expect(ShardPlan(floor: nil, grown: ["not-a-week": 8]).count(week: week) == nil)
    }

    @Test("A slot that lost enough races doubles its week, starting from the plan it had")
    func raisedDoublesTheContendedWeek() {
        let slot = slot(aggregate: "by_product", group: "app")
        let plans: ShardPlans = ["by_product": ShardPlan(floor: 4)]

        let raised = plans.raised(lost: [slot: 3])

        #expect(raised == [slot.headIndex: IndexPage(weeks: [], groups: [], shards: [key: 8])])
    }

    @Test("A slot under the threshold, or of an unplanned aggregate, raises from one")
    func raisedBelowThresholdAndUnplanned() {
        let quiet = slot(aggregate: "by_product", group: "app")
        let unplanned = slot(aggregate: "by_region", group: "eu")
        let plans: ShardPlans = ["by_product": ShardPlan(floor: 4)]

        let raised = plans.raised(lost: [quiet: 2, unplanned: 3])

        #expect(raised == [unplanned.headIndex: IndexPage(weeks: [], groups: [], shards: [key: 2])])
    }
}
