//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// The measured CloudKit parallelism ceiling every request goes through.
///
/// Re-validate with `verifyParallelismBenchmark` if CloudKit's behavior changes.
public let cloudKitParallelismLimit = 8

let requestLimiter = RequestLimiter(limit: cloudKitParallelismLimit)

/// An asynchronous semaphore that caps the number of CloudKit requests in flight.
///
/// Query latency scales near-perfectly up to `cloudKitParallelismLimit` concurrent
/// requests and degrades beyond that — see `benchmarkCloudKitParallelism`. The limit
/// keeps every store operation inside the well-scaling range no matter how many call
/// sites fan out at once.
///
actor RequestLimiter {
    private let limit: Int
    private var running = 0
    private var isDraining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var drained: CheckedContinuation<Void, Never>?

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits until a request slot is free and claims it; pair with `release()`.
    func acquire() async {
        if !isDraining && running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
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

    /// Claims every slot at once, giving measurement code exclusive access to CloudKit.
    ///
    /// Waits out in-flight requests and blocks new ones until `releaseAll()`. Drains are
    /// atomic — concurrent callers queue up instead of deadlocking on each other's
    /// partially claimed slots.
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
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` while holding one request slot.
    nonisolated func withSlot<R>(body: () async throws -> R) async rethrows -> R {
        try await holding({ await acquire() }, until: { await release() }, body: body)
    }

    /// Runs `body` while holding every slot, giving it exclusive access to CloudKit.
    nonisolated func withAllSlots<R>(body: () async throws -> R) async rethrows -> R {
        try await holding({ await acquireAll() }, until: { await releaseAll() }, body: body)
    }

    nonisolated private func holding<R>(_ claim: () async -> Void, until free: () async -> Void, body: () async throws -> R) async rethrows -> R {
        await claim()
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

extension CKDatabase {
    @discardableResult func throttled<R>(body: @Sendable @escaping (CKDatabase) async throws -> R) async throws -> R {
        try await requestLimiter.withSlot {
            try await withRequestTimeout(requestTimeout) {
                try await self.configuredWith(configuration: .scoutDB, body: body)
            }
        }
    }
}

/// Thrown when a CloudKit request outlives the scout-db backstop timeout and is
/// cancelled, freeing its request slot instead of stalling the whole pool.
public struct RequestTimeoutError: LocalizedError {
    /// The elapsed limit, in seconds, the request exceeded before cancellation.
    public let seconds: Int

    public var errorDescription: String? {
        "The CloudKit request exceeded the \(seconds)s scout-db timeout and was cancelled."
    }
}

// A backstop above CloudKit's own 10s request/resource timeout: a write can stall
// server-side without that timeout firing, so this cancels the operation and frees
// its request slot rather than letting a single stuck call starve the pool.
private let requestTimeout: Duration = .seconds(30)

// Carries a request result across the timeout task boundary even when the payload
// (e.g. CKRecord) is not Sendable; only one task ever produces it.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

// Races `operation` against a timer; the loser is cancelled, so a stuck request
// throws `RequestTimeoutError` and frees its slot instead of stalling the pool.
func withRequestTimeout<R>(_ timeout: Duration, _ operation: @Sendable @escaping () async throws -> R) async throws -> R {
    try await withThrowingTaskGroup(of: UncheckedBox<R>.self) { group in
        group.addTask { UncheckedBox(value: try await operation()) }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RequestTimeoutError(seconds: Int(timeout.components.seconds))
        }
        defer { group.cancelAll() }
        return try await group.next()!.value
    }
}

extension CKOperation.Configuration {
    /// The configuration for every ScoutDB request, benchmark requests included.
    static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
