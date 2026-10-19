//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct RequestTimeoutError: LocalizedError {
    let seconds: Int

    var errorDescription: String? {
        "The CloudKit request exceeded the \(seconds)s scout-db timeout and was cancelled."
    }
}

func withRequestTimeout<R>(timeout: Duration, operation: @Sendable @escaping () async throws -> R) async throws -> R {
    let relay = ResultRelay<R>()

    let operationTask = Task {
        do {
            await relay.finish(result: .success(try await operation()))
        } catch {
            await relay.finish(result: .failure(error))
        }
    }

    let timerTask = Task {
        try await Task.sleep(for: timeout)
        await relay.finish(result: .failure(RequestTimeoutError(seconds: Int(timeout.components.seconds))))
    }

    defer {
        operationTask.cancel()
        timerTask.cancel()
    }

    return try await withTaskCancellationHandler {
        try await relay.value()
    } onCancel: {
        relay.cancel()
    }
}

private actor ResultRelay<T> {
    private struct Box: @unchecked Sendable {
        let value: T
    }

    private var result: Result<Box, any Error>?
    private var continuation: CheckedContinuation<Box, any Error>?

    func finish(result: Result<T, any Error>) {
        guard self.result == nil else {
            return
        }
        let boxed = result.map(Box.init)
        self.result = boxed
        continuation?.resume(with: boxed)
        continuation = nil
    }

    nonisolated func cancel() {
        Task { await finish(result: .failure(CancellationError())) }
    }

    func value() async throws -> sending T {
        if let result {
            return try result.get().value
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }.value
    }
}
