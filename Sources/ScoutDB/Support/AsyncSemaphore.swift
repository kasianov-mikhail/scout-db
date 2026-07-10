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
    private var drainWaiters: [Waiter] = []
    private var drained: Waiter?

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    // The three places a caller can be parked, all sharing the same
    // registration and cancellation handling.
    private enum Spot {
        /// Waiting for a single slot to free up.
        case slot
        /// Waiting to be handed ownership of the drain.
        case drain
        /// Owning the drain, waiting for in-flight operations to finish.
        case drained
    }

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits until a slot is free and claims it; pair with `release()`.
    ///
    /// Throws `CancellationError` without holding a slot when the task is cancelled,
    /// so an abandoned caller leaves the queue instead of parking until a slot frees;
    /// a slot granted in the same instant cancellation lands is handed on.
    ///
    func acquire() async throws {
        try Task.checkCancellation()
        if !isDraining && running < limit {
            running += 1
            return
        }
        try await park(in: .slot)
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Frees the slot, handing it to the longest-waiting request if any.
    func release() {
        precondition(running > 0, "release() without a matching acquire()")
        running -= 1
        if isDraining {
            if running == 0, let owner = drained {
                drained = nil
                owner.continuation.resume(returning: ())
            }
            return
        }
        resumeWaiters()
    }

    /// Claims every slot at once, giving callers exclusive access to the resource.
    ///
    /// Waits out in-flight operations and blocks new ones until `releaseAll()`.
    /// Drains are atomic: concurrent callers queue up instead of deadlocking on each
    /// other's partially claimed slots, and ownership passes directly from one drain
    /// to the next so no `acquire()` can barge in between them.
    ///
    /// Throws `CancellationError` without holding the drain when the task is
    /// cancelled, handing a partially claimed drain to the next queued caller.
    ///
    func acquireAll() async throws {
        try Task.checkCancellation()
        if isDraining {
            try await park(in: .drain)
        } else {
            isDraining = true
        }
        do {
            if running > 0 {
                try await park(in: .drained)
            }
            try Task.checkCancellation()
        } catch {
            handOffDrain()
            throw error
        }
    }

    /// Releases the drain claimed by `acquireAll()`.
    func releaseAll() {
        precondition(isDraining, "releaseAll() without a matching acquireAll()")
        handOffDrain()
    }

    // Passes drain ownership to the next queued drain, or reopens the slots.
    // Ownership transfers while `isDraining` stays true, so no acquire() can
    // slip in between two drains.
    private func handOffDrain() {
        if drainWaiters.count > 0 {
            drainWaiters.removeFirst().continuation.resume(returning: ())
            return
        }
        isDraining = false
        resumeWaiters()
    }

    private func park(in spot: Spot) async throws {
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, continuation: continuation)
                switch spot {
                case .slot: waiters.append(waiter)
                case .drain: drainWaiters.append(waiter)
                case .drained: drained = waiter
                }
                // Cancellation may have fired before the waiter was registered,
                // in which case the onCancel hop found nothing to remove.
                if Task.isCancelled { cancel(waiterID: id, in: spot) }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: id, in: spot) }
        }
    }

    private func cancel(waiterID id: Int, in spot: Spot) {
        switch spot {
        case .slot:
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        case .drain:
            guard let index = drainWaiters.firstIndex(where: { $0.id == id }) else { return }
            drainWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        case .drained:
            guard let owner = drained, owner.id == id else { return }
            drained = nil
            owner.continuation.resume(throwing: CancellationError())
        }
    }

    private func resumeWaiters() {
        while running < limit, waiters.count > 0 {
            running += 1
            waiters.removeFirst().continuation.resume(returning: ())
        }
    }

    /// Runs `body` while holding every slot.
    ///
    /// Throws `CancellationError` without running `body` when the task is cancelled
    /// while waiting for the drain.
    ///
    nonisolated func withAllSlots<R>(body: () async throws -> R) async throws -> R {
        try await acquireAll()
        do {
            let result = try await body()
            await releaseAll()
            return result
        } catch {
            await releaseAll()
            throw error
        }
    }
}
