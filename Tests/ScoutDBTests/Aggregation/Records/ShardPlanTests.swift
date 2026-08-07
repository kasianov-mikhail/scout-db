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

    @Test("An undeclared, uncontended week is unsharded and reached by the bare name")
    func bareWeek() {
        let plan = ShardPlan(floor: nil)

        #expect(plan.count(for: week) == nil)
        #expect(plan.shards(for: week) == [nil])
    }

    @Test("The schema's count is the floor a week starts from")
    func floorHolds() {
        let plan = ShardPlan(floor: 4)

        #expect(plan.count(for: week) == 4)
        #expect(plan.shards(for: week) == [0, 1, 2, 3])
    }

    @Test("A week that outgrew the floor keeps the larger of the two")
    func growthOutranksTheFloor() {
        #expect(ShardPlan(floor: 4, grown: [key: 16]).count(for: week) == 16)
        #expect(ShardPlan(floor: 16, grown: [key: 4]).count(for: week) == 16)
    }

    @Test("Doubling raises the one week and leaves its neighbours where they were")
    func doublingIsPerWeek() {
        let plan = ShardPlan(floor: nil).doubling(week).doubling(week)

        #expect(plan.count(for: week) == 4)
        #expect(plan.count(for: other) == nil)
    }

    @Test("An unsharded week doubles into two, so what it already holds stays at shard zero")
    func firstDoublingKeepsTheBareRecord() {
        let plan = ShardPlan(floor: nil).doubling(week)

        #expect(plan.count(for: week) == 2)
        #expect(plan.shards(for: week) == [0, 1])
    }

    @Test("A plan round-trips through the page it is stored on")
    func storedRoundTrip() {
        let plan = ShardPlan(floor: 2, grown: [key: 8])
        let page = VectorIndex.Page(weeks: [], groups: [], shards: plan.stored)

        #expect(ShardPlan(floor: 2, page: page) == plan)
    }
}
