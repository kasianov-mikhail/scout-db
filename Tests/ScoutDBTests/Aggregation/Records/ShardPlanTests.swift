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
        #expect(ShardPlan(floor: nil).count(for: week) == nil)
    }

    @Test("The schema's count is the floor a week starts from")
    func floorHolds() {
        #expect(ShardPlan(floor: 4).count(for: week) == 4)
    }

    @Test("A week that outgrew the floor keeps the larger of the two")
    func growthOutranksTheFloor() {
        #expect(ShardPlan(floor: 4, grown: [key: 16]).count(for: week) == 16)
        #expect(ShardPlan(floor: 16, grown: [key: 4]).count(for: week) == 16)
    }

    @Test("A week that grew leaves its neighbours where they were")
    func growthIsPerWeek() {
        let plan = ShardPlan(floor: nil, grown: [key: 4])

        #expect(plan.count(for: week) == 4)
        #expect(plan.count(for: other) == nil)
    }

    @Test("A count that will not parse as a week is dropped rather than mistaken for one")
    func unparsableWeekIsDropped() {
        #expect(ShardPlan(floor: nil, grown: ["not-a-week": 8]).count(for: week) == nil)
    }
}
