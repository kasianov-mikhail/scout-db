//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {
    @Test("Acquires up to the limit without suspending")
    func testAcquiresUpToLimit() async throws {
        let limiter = AsyncSemaphore(limit: 3)

        // Would hang here if the limiter blocked before reaching its limit.
        for _ in 0..<3 {
            try await limiter.acquire()
        }

        for _ in 0..<3 {
            await limiter.release()
        }
    }

    @Test("Never exceeds the limit under contention")
    func testCapsConcurrency() async throws {
        let limiter = AsyncSemaphore(limit: 3)
        let tracker = Tracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await limiter.acquire()
                    await tracker.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await tracker.exit()
                    await limiter.release()
                }
            }
            try await group.waitForAll()
        }

        #expect(await tracker.maxConcurrent <= 3)
        #expect(await tracker.total == 20)
    }

    @Test("Release hands the slot to a waiter")
    func testWaiterResumes() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.acquire()

        let waiter = Task {
            try await limiter.acquire()
            return true
        }

        try? await Task.sleep(for: .milliseconds(50))
        await limiter.release()

        #expect(try await waiter.value)
        await limiter.release()
    }

    @Test("A cancelled waiter throws instead of staying parked")
    func testCancelledWaiterThrows() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.acquire()

        let waiter = Task {
            try await limiter.acquire()
        }

        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }

        await limiter.release()
        // Would hang here if the cancelled waiter had consumed the freed slot.
        try await limiter.acquire()
        await limiter.release()
    }

    @Test("Release hands the slot past a cancelled waiter to the next one")
    func testReleaseSkipsCancelledWaiter() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.acquire()

        let cancelled = Task {
            try await limiter.acquire()
        }
        try? await Task.sleep(for: .milliseconds(50))

        let next = Task {
            try await limiter.acquire()
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await limiter.release()
        #expect(try await next.value)
        await limiter.release()
    }

    @Test("Acquire throws on an already-cancelled task without taking a slot")
    func testAlreadyCancelledAcquireThrows() async throws {
        let limiter = AsyncSemaphore(limit: 1)

        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            try await limiter.acquire()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // Would hang here if the cancelled task had claimed the free slot.
        try await limiter.acquire()
        await limiter.release()
    }

    @Test("acquireAll blocks new requests until releaseAll")
    func testAcquireAllBlocksUntilReleaseAll() async throws {
        let limiter = AsyncSemaphore(limit: 2)
        try await limiter.acquireAll()

        let entered = Box(false)
        let waiter = Task {
            try await limiter.acquire()
            entered.value = true
            await limiter.release()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(!entered.value)

        await limiter.releaseAll()
        try await waiter.value

        #expect(entered.value)
    }

    @Test("Concurrent acquireAll calls serialize instead of deadlocking")
    func testConcurrentAcquireAllSerializes() async throws {
        let limiter = AsyncSemaphore(limit: 4)
        try await limiter.acquire()

        let drains = [
            Task {
                try await limiter.withAllSlots { true }
            },
            Task {
                try await limiter.withAllSlots { true }
            },
        ]

        // Both drains are now waiting for the held slot; with per-slot
        // acquisition they would deadlock on each other's partial claims.
        try? await Task.sleep(for: .milliseconds(50))
        await limiter.release()

        for drain in drains {
            #expect(try await drain.value)
        }
    }

    @Test("acquireAll throws on an already-cancelled task without claiming the drain")
    func testAlreadyCancelledAcquireAllThrows() async throws {
        let limiter = AsyncSemaphore(limit: 1)

        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            try await limiter.acquireAll()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // Would hang here if the cancelled task had claimed the drain.
        try await limiter.acquire()
        await limiter.release()
    }

    @Test("A cancelled queued drain throws and the chain continues past it")
    func testCancelledDrainWaiterThrows() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.acquireAll()

        let cancelled = Task {
            try await limiter.acquireAll()
        }
        try? await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await limiter.releaseAll()
        // Would hang here if the drain had been handed to the cancelled caller.
        try await limiter.acquire()
        await limiter.release()
    }

    @Test("Cancelling a drain that is waiting out a slot hands the semaphore back")
    func testCancelledDrainOwnerHandsBack() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.acquire()

        let drain = Task {
            try await limiter.acquireAll()
        }
        try? await Task.sleep(for: .milliseconds(50))
        drain.cancel()

        await #expect(throws: CancellationError.self) {
            try await drain.value
        }

        await limiter.release()
        // Would hang here if the abandoned drain still blocked new requests.
        try await limiter.acquire()
        await limiter.release()
    }

    @Test("A stream of drains cannot starve a waiter queued between them")
    func testDrainsDoNotStarveWaiters() async throws {
        let limiter = AsyncSemaphore(limit: 2)
        try await limiter.acquireAll()

        // The single-slot waiter parks first, a second drain after it. With
        // drain-first hand-off the drain chain would keep ownership and the
        // waiter would starve; FIFO order serves the waiter in between.
        let events = Events()
        let waiter = Task {
            try await limiter.acquire()
            await events.append("acquire")
            await limiter.release()
        }
        try? await Task.sleep(for: .milliseconds(50))

        let drain = Task {
            try await limiter.withAllSlots {
                await events.append("drain")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        await limiter.releaseAll()
        try await waiter.value
        try await drain.value

        #expect(await events.log == ["acquire", "drain"])
    }

    @Test("A waiter parked behind a queued drain runs after it, not around it")
    func testWaitersQueueBehindDrain() async throws {
        let limiter = AsyncSemaphore(limit: 2)
        try await limiter.acquire()

        let events = Events()
        // The drain parks first (one slot is busy), then a single-slot waiter.
        // A free slot exists, but granting it would let requests leapfrog the
        // drain forever — the waiter must wait its turn behind the drain.
        let drain = Task {
            try await limiter.withAllSlots {
                await events.append("drain")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        let waiter = Task {
            try await limiter.acquire()
            await events.append("acquire")
            await limiter.release()
        }
        try? await Task.sleep(for: .milliseconds(50))

        await limiter.release()
        try await drain.value
        try await waiter.value

        #expect(await events.log == ["drain", "acquire"])
    }
}

@Suite("CloudKitRequestLimiter")
struct CloudKitRequestLimiterTests {
    @Test("The backstop clock starts when the slot is granted, not when the request queues")
    func testTimeoutExcludesQueueTime() async throws {
        let limiter = CloudKitRequestLimiter(limit: 1, timeout: .milliseconds(500), monitor: RequestActivityMonitor())

        // Back to back the two requests take ~600ms of wall time - past the
        // 500ms backstop; the second would spuriously time out if its clock
        // covered the time it spends queued behind the first.
        async let first: Void = limiter.withSlot {
            try? await Task.sleep(for: .milliseconds(300))
        }
        async let second: Void = limiter.withSlot {
            try? await Task.sleep(for: .milliseconds(300))
        }
        try await first
        try await second
    }

    @Test("A timed-out request keeps its slot until it actually settles")
    func testAbandonedRequestHoldsSlot() async throws {
        let limiter = CloudKitRequestLimiter(limit: 1, timeout: .milliseconds(50), monitor: RequestActivityMonitor())
        let settled = Box(false)

        let stuck = Task {
            try await limiter.withSlot {
                // A request that ignores cancellation: detached work resumes
                // the continuation on its own schedule, like a stalled
                // CloudKit call that outlives the backstop.
                await withCheckedContinuation { continuation in
                    Task.detached {
                        try? await Task.sleep(for: .milliseconds(200))
                        settled.value = true
                        continuation.resume()
                    }
                }
            }
        }
        await #expect(throws: RequestTimeoutError.self) {
            try await stuck.value
        }

        // The next request must wait for the abandoned one to settle instead
        // of running alongside it past the parallelism limit.
        try await limiter.withSlot {
            #expect(settled.value)
        }
    }
}

private actor Events {
    private(set) var log: [String] = []

    func append(_ event: String) {
        log.append(event)
    }
}

private actor Tracker {
    private var current = 0

    var maxConcurrent = 0
    var total = 0

    func enter() {
        current += 1
        total += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func exit() {
        current -= 1
    }
}

/// A mutable reference cell for observing side effects of `Sendable` closures in tests.
private final class Box<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }
}
