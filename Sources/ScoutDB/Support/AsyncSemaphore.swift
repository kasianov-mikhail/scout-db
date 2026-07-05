//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

/// An asynchronous semaphore that caps the number of concurrent operations.
actor AsyncSemaphore {
    private let limit: Int
    private var running = 0
    private var isDraining = false
    private var nextWaiterID = 0
    private var waiters: [Waiter] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var drained: CheckedContinuation<Void, Never>?

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits until a slot is free and claims it; pair with `release()`.
    ///
    /// Throws `CancellationError` without claiming a slot when the task is cancelled,
    /// so an abandoned caller leaves the queue instead of parking until a slot frees.
    ///
    func acquire() async throws {
        try Task.checkCancellation()
        if !isDraining && running < limit {
            running += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                // Cancellation may have fired before the waiter was registered,
                // in which case the onCancel hop found nothing to remove.
                if Task.isCancelled { cancelWaiter(id: id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Frees the slot, handing it to the longest-waiting request if any.
    func release() {
        running -= 1
        if isDraining {
            if running == 0 {
                drained?.resume()
                drained = nil
            }
            return
        }
        resumeWaiters()
    }

    /// Claims every slot at once, giving callers exclusive access to the resource.
    ///
    /// Waits out in-flight operations and blocks new ones until `releaseAll()`.
    /// Drains are atomic: concurrent callers queue up instead of deadlocking on each
    /// other's partially claimed slots.
    ///
    func acquireAll() async {
        while isDraining {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }
        isDraining = true
        if running > 0 {
            await withCheckedContinuation { continuation in
                drained = continuation
            }
        }
        running = limit
    }

    /// Releases all slots claimed by `acquireAll()`.
    func releaseAll() {
        running = 0
        isDraining = false
        if drainWaiters.count > 0 {
            drainWaiters.removeFirst().resume()
            return
        }
        resumeWaiters()
    }

    private func resumeWaiters() {
        while running < limit, waiters.count > 0 {
            running += 1
            waiters.removeFirst().continuation.resume(returning: ())
        }
    }

    /// Runs `body` while holding one slot.
    ///
    /// Throws `CancellationError` without running `body` when the task is cancelled
    /// while waiting for a slot.
    ///
    nonisolated func withSlot<R>(body: () async throws -> R) async throws -> R {
        try await holding({ try await acquire() }, until: { await release() }, body: body)
    }

    /// Runs `body` while holding every slot.
    nonisolated func withAllSlots<R>(body: () async throws -> R) async rethrows -> R {
        try await holding({ await acquireAll() }, until: { await releaseAll() }, body: body)
    }

    nonisolated private func holding<R>(_ claim: () async throws -> Void, until free: () async -> Void, body: () async throws -> R) async rethrows -> R {
        try await claim()
        do {
            let result = try await body()
            await free()
            return result
        } catch {
            await free()
            throw error
        }
    }
}
