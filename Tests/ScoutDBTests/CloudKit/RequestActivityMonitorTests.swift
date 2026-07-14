//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Testing

@testable import ScoutDB

@Suite("RequestActivityMonitor")
struct RequestActivityMonitorTests {
    @Test("A new subscriber receives the current count immediately")
    func testInitialValue() async {
        let monitor = RequestActivityMonitor()

        var updates = monitor.updates.makeAsyncIterator()

        #expect(await updates.next() == 0)
    }

    @Test("A subscriber arriving mid-flight starts from the in-flight count")
    func testMidFlightSubscription() async {
        let monitor = RequestActivityMonitor()
        await monitor.began()
        await monitor.began()

        var updates = monitor.updates.makeAsyncIterator()

        #expect(await updates.next() == 2)
    }

    @Test("Publishes every change to every subscriber")
    func testPublishesChanges() async {
        let monitor = RequestActivityMonitor()
        var first = monitor.updates.makeAsyncIterator()
        var second = monitor.updates.makeAsyncIterator()
        #expect(await first.next() == 0)
        #expect(await second.next() == 0)

        await monitor.began()
        #expect(await first.next() == 1)
        #expect(await second.next() == 1)

        await monitor.ended()
        #expect(await first.next() == 0)
        #expect(await second.next() == 0)
    }

    @Test("The limiter reports a slot as active until the request settles")
    func testLimiterReportsSlotActivity() async throws {
        let monitor = RequestActivityMonitor()
        let limiter = CloudKitRequestLimiter(limit: 2, timeout: .seconds(5), monitor: monitor)
        var updates = monitor.updates.makeAsyncIterator()
        #expect(await updates.next() == 0)

        try await limiter.withSlot {}

        #expect(await updates.next() == 1)
        #expect(await updates.next() == 0)
    }

    @Test("A failing request still ends its activity")
    func testFailingRequestEndsActivity() async throws {
        let monitor = RequestActivityMonitor()
        let limiter = CloudKitRequestLimiter(limit: 2, timeout: .seconds(5), monitor: monitor)
        var updates = monitor.updates.makeAsyncIterator()
        #expect(await updates.next() == 0)

        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await limiter.withSlot { throw Failure() }
        }

        #expect(await updates.next() == 1)
        #expect(await updates.next() == 0)
    }
}
