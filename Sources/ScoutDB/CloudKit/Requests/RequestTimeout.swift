//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// Thrown when a CloudKit request outlives the scout-db backstop timeout; the
/// caller is unblocked immediately while the request is cancelled and abandoned
/// to finish in the background.
struct RequestTimeoutError: LocalizedError {
    /// The elapsed limit, in seconds, the request exceeded before cancellation.
    let seconds: Int

    var errorDescription: String? {
        "The CloudKit request exceeded the \(seconds)s scout-db timeout and was cancelled."
    }
}

func withRequestTimeout<R>(_ timeout: Duration, _ operation: @Sendable @escaping () async throws -> R) async throws -> R
{
    let relay = ResultRelay<R>()

    let operationTask = Task {
        do {
            await relay.finish(with: .success(try await operation()))
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
        try await relay.value()
    } onCancel: {
        Task { await relay.finish(with: .failure(CancellationError())) }
    }
}

private actor ResultRelay<T> {
    private struct Box: @unchecked Sendable {
        let value: T
    }

    private var result: Result<Box, any Error>?
    private var continuation: CheckedContinuation<Box, any Error>?

    func finish(with result: Result<T, any Error>) {
        guard self.result == nil else {
            return
        }
        let boxed = result.map(Box.init)
        self.result = boxed
        continuation?.resume(with: boxed)
        continuation = nil
    }

    func value() async throws -> sending T {
        if let result {
            return try result.get().value
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }.value
    }
}
