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

let requestLimiter = CloudKitRequestLimiter(limit: cloudKitParallelismLimit, timeout: requestTimeout)

// A backstop above CloudKit's own 10s request/resource timeout: a write can stall
// server-side without that timeout firing, so this cancels the operation and frees
// its request slot rather than letting a single stuck call starve the pool.
private let requestTimeout: Duration = .seconds(30)

/// Applies ScoutDB's CloudKit request policy: bounded parallelism plus a backstop timeout.
///
/// Query latency scales near-perfectly up to `cloudKitParallelismLimit` concurrent
/// requests and degrades beyond that - see `benchmarkCloudKitParallelism`. The limit
/// keeps every store operation inside the well-scaling range no matter how many call
/// sites fan out at once.
///
struct CloudKitRequestLimiter {
    private let semaphore: AsyncSemaphore
    private let timeout: Duration

    init(limit: Int, timeout: Duration) {
        self.semaphore = AsyncSemaphore(limit: limit)
        self.timeout = timeout
    }

    func withSlot<R>(body: @Sendable @escaping () async throws -> R) async throws -> R {
        try await semaphore.withSlot {
            try await withRequestTimeout(timeout, body)
        }
    }

    func withAllSlots<R>(body: () async throws -> R) async rethrows -> R {
        try await semaphore.withAllSlots(body: body)
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

extension CKOperation.Configuration {
    /// The configuration for every ScoutDB request, benchmark requests included.
    static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
