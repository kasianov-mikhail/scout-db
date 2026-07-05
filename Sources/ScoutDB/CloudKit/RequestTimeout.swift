//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// Thrown when a CloudKit request outlives the scout-db backstop timeout and is
/// cancelled, freeing its request slot instead of stalling the whole pool.
public struct RequestTimeoutError: LocalizedError {
    /// The elapsed limit, in seconds, the request exceeded before cancellation.
    public let seconds: Int

    public var errorDescription: String? {
        "The CloudKit request exceeded the \(seconds)s scout-db timeout and was cancelled."
    }
}

// Carries a request result across the timeout task boundary even when the payload
// (e.g. CKRecord) is not Sendable; only one task ever produces it.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

// Races `operation` against a timer; the loser is cancelled. Both racers run as
// unstructured tasks so the timeout (or the caller's cancellation) surfaces
// immediately even when the operation never honors its cancellation - a structured
// group would swallow the timeout error until the stuck child resumed.
func withRequestTimeout<R>(_ timeout: Duration, _ operation: @Sendable @escaping () async throws -> R) async throws -> R {
    let relay = ResultRelay<UncheckedBox<R>>()
    let operationTask = Task {
        do {
            await relay.finish(with: .success(UncheckedBox(value: try await operation())))
        } catch {
            await relay.finish(with: .failure(error))
        }
    }
    let timerTask = Task {
        try await Task.sleep(for: timeout)
        await relay.finish(with: .failure(RequestTimeoutError(seconds: Int(timeout.components.seconds))))
    }
    defer {
        operationTask.cancel()
        timerTask.cancel()
    }
    return try await withTaskCancellationHandler {
        try await relay.value().value
    } onCancel: {
        Task { await relay.finish(with: .failure(CancellationError())) }
    }
}

// Delivers whichever racer finishes first and drops the rest, letting the caller
// abandon a loser that never finishes.
private actor ResultRelay<T: Sendable> {
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    func finish(with result: Result<T, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
