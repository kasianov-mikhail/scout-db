//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("RequestTimeout")
struct RequestTimeoutTests {
    @Test("Returns the value when the operation finishes in time")
    func testPassesThroughFastResult() async throws {
        let value = try await withRequestTimeout(.seconds(10)) { 42 }
        #expect(value == 42)
    }

    @Test("Throws RequestTimeoutError when the operation outlives the limit")
    func testThrowsOnTimeout() async {
        await #expect(throws: RequestTimeoutError.self) {
            try await withRequestTimeout(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(10))
            }
        }
    }

    @Test("Times out on schedule even when the operation ignores cancellation")
    func testEscapesStuckOperation() async {
        let gate = Gate()
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: RequestTimeoutError.self) {
            try await withRequestTimeout(.milliseconds(20)) {
                await gate.wait()
            }
        }

        #expect(clock.now - start < .seconds(5))
        await gate.open()
    }

    @Test("Rethrows the caller's cancellation instead of waiting out the timer")
    func testPropagatesCallerCancellation() async {
        let task = Task {
            try await withRequestTimeout(.seconds(10)) {
                try await Task.sleep(for: .seconds(10))
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

// Parks callers on a plain continuation that ignores task cancellation, standing in
// for a request stuck past the point where cancelling it helps.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        while waiters.count > 0 {
            waiters.removeFirst().resume()
        }
    }
}
