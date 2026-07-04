//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("RequestLimiter")
struct RequestLimiterTests {
    @Test("Acquires up to the limit without suspending")
    func testAcquiresUpToLimit() async throws {
        let limiter = RequestLimiter(limit: 3)

        // Would hang here if the limiter blocked before reaching its limit.
        for _ in 0..<3 {
            try await limiter.acquire()
        }

        await limiter.releaseAll()
    }

    @Test("Never exceeds the limit under contention")
    func testCapsConcurrency() async throws {
        let limiter = RequestLimiter(limit: 3)
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
        let limiter = RequestLimiter(limit: 1)
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
        let limiter = RequestLimiter(limit: 1)
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
        let limiter = RequestLimiter(limit: 1)
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
        let limiter = RequestLimiter(limit: 1)

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
        let limiter = RequestLimiter(limit: 2)
        await limiter.acquireAll()

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
        let limiter = RequestLimiter(limit: 4)
        try await limiter.acquire()

        let drains = [
            Task {
                await limiter.withAllSlots { true }
            },
            Task {
                await limiter.withAllSlots { true }
            },
        ]

        // Both drains are now waiting for the held slot; with per-slot
        // acquisition they would deadlock on each other's partial claims.
        try? await Task.sleep(for: .milliseconds(50))
        await limiter.release()

        for drain in drains {
            #expect(await drain.value)
        }
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
