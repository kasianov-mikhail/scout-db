//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

/// An asynchronous semaphore that caps the number of concurrent operations.
///
/// Single-slot waiters and whole-semaphore drains share one FIFO queue, so
/// neither kind can starve the other: a stream of drains lets the requests
/// queued between them through in arrival order, and a stream of requests
/// cannot hold a queued drain off forever.
///
actor AsyncSemaphore {
    private let limit: Int
    private var running = 0
    private var isDraining = false
    private var nextWaiterID = 0
    private var queue: [Waiter] = []

    private struct Waiter {
        let id: Int
        /// Whether the waiter needs every slot (a drain) or just one.
        let wantsDrain: Bool
        let continuation: CheckedContinuation<Void, any Error>
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
        // The fast path only applies to an empty queue: barging past parked
        // waiters would break the arrival order that fairness rests on.
        if queue.isEmpty && !isDraining && running < limit {
            running += 1
            return
        }
        try await park(wantsDrain: false)
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Frees the slot, handing it to the longest-waiting request if any.
    func release() {
        precondition(running > 0, "release() without a matching acquire()")
        running -= 1
        admitFromQueue()
    }

    /// Claims every slot at once, giving callers exclusive access to the resource.
    ///
    /// Waits out in-flight operations and blocks new ones until `releaseAll()`.
    /// Drains are atomic: concurrent callers queue up instead of deadlocking on
    /// each other's partially claimed slots. The queue is strictly FIFO — a
    /// request parked before the drain runs first, one parked after it waits.
    ///
    /// Throws `CancellationError` without holding the drain when the task is
    /// cancelled, letting the queue move past the abandoned claim.
    ///
    func acquireAll() async throws {
        try Task.checkCancellation()
        if queue.isEmpty && !isDraining && running == 0 {
            isDraining = true
        } else {
            try await park(wantsDrain: true)
        }
        if Task.isCancelled {
            releaseAll()
            throw CancellationError()
        }
    }

    /// Releases the drain claimed by `acquireAll()`.
    func releaseAll() {
        precondition(isDraining, "releaseAll() without a matching acquireAll()")
        isDraining = false
        admitFromQueue()
    }

    // Grants the queue head as long as the semaphore can honor it: a slot
    // waiter needs a free slot and no drain, a drain needs full quiescence.
    // A drain at the head thus also blocks the slot waiters behind it — that
    // is what lets it ever reach zero running under load.
    private func admitFromQueue() {
        while let head = queue.first, !isDraining {
            if head.wantsDrain {
                guard running == 0 else { return }
                isDraining = true
            } else {
                guard running < limit else { return }
                running += 1
            }
            queue.removeFirst().continuation.resume(returning: ())
        }
    }

    private func park(wantsDrain: Bool) async throws {
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Waiter(id: id, wantsDrain: wantsDrain, continuation: continuation))
                // Cancellation may have fired before the waiter was registered,
                // in which case the onCancel hop found nothing to remove.
                if Task.isCancelled { cancel(waiterID: id) }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: id) }
        }
    }

    private func cancel(waiterID id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
        // Removing a parked drain may unblock the waiters queued behind it.
        admitFromQueue()
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
