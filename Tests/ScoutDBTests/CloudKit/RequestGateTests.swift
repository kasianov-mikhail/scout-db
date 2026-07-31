//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Request gate")
struct RequestGateTests {
    @Test("A fan-out wider than the limit never runs more than the limit at once")
    func capsConcurrency() async throws {
        let gate = RequestGate(limit: 3)
        let peak = Peak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.enter()
                    await peak.entered()
                    try? await Task.sleep(for: .milliseconds(2))
                    await peak.left()
                    await gate.leave()
                }
            }
            await group.waitForAll()
        }

        #expect(await peak.highest <= 3)
        #expect(await peak.highest > 1)
    }

    @Test("A raised limit lets the waiters through without a slot being returned")
    func raisingTheLimitAdmitsWaiters() async throws {
        let gate = RequestGate(limit: 1)
        await gate.enter()

        let waiter = Task {
            await gate.enter()
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(waiter.isCancelled == false)

        await gate.setLimit(4)
        #expect(await waiter.value)
        #expect(await gate.currentLimit == 4)
    }

    @Test("Returning a slot with nobody waiting frees it for the next arrival")
    func slotsAreReusable() async throws {
        let gate = RequestGate(limit: 2)
        for _ in 0..<5 {
            await gate.enter()
            await gate.leave()
        }
        await gate.enter()
        await gate.enter()
        await gate.leave()
        await gate.leave()
    }
}

private actor Peak {
    private var current = 0
    private(set) var highest = 0

    func entered() {
        current += 1
        highest = Swift.max(highest, current)
    }

    func left() {
        current -= 1
    }
}
