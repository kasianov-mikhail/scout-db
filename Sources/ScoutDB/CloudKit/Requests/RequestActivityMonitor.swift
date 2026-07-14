//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

/// The monitor every `CloudKitRequestLimiter` slot reports to.
public let cloudKitRequestActivity = RequestActivityMonitor()

/// Publishes the number of CloudKit requests currently holding a limiter slot.
///
/// A request counts from the moment it claims a slot until it actually settles —
/// through rate-limit backoff and past the backstop timeout — so the published
/// count mirrors true slot occupancy, never exceeding `cloudKitParallelismLimit`.
///
public actor RequestActivityMonitor {
    private var running = 0
    private var nextSubscriberID = 0
    private var subscribers: [Int: AsyncStream<Int>.Continuation] = [:]

    /// The in-flight request count: the current value on subscription, then every change.
    public nonisolated var updates: AsyncStream<Int> {
        AsyncStream { continuation in
            Task { await self.register(continuation) }
        }
    }

    func began() {
        running += 1
        publish()
    }

    func ended() {
        precondition(running > 0, "ended() without a matching began()")
        running -= 1
        publish()
    }

    private func publish() {
        for continuation in subscribers.values {
            continuation.yield(running)
        }
    }

    private func register(_ continuation: AsyncStream<Int>.Continuation) {
        let id = nextSubscriberID
        nextSubscriberID += 1
        continuation.onTermination = { _ in
            Task { await self.unregister(id) }
        }
        subscribers[id] = continuation
        continuation.yield(running)
    }

    private func unregister(_ id: Int) {
        subscribers[id] = nil
    }
}
