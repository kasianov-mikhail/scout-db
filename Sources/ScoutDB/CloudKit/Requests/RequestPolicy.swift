//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

let requestTimeout: Duration = .seconds(30)

extension CKDatabase {
    /// Sends one request under the store's pacing: a slot from the gate, the
    /// backstop timeout, and a retry for the two errors that ask for one.
    ///
    /// The slot is taken per attempt and given back before a retry waits, so a
    /// request sitting out a rate limit does not hold the gate closed behind
    /// it. Waiting for a slot is outside the timeout — a queue is congestion,
    /// not a stalled request, and reporting it as a timeout would send an
    /// `OfflineCache` to its snapshots while the network is fine.
    ///
    @discardableResult func throttled<R>(body: @Sendable @escaping (CKDatabase) async throws -> R) async throws -> R {
        try await withRateLimitRetry {
            await RequestGate.shared.enter()
            do {
                let value = try await withRequestTimeout(requestTimeout) {
                    try await self.configuredWith(configuration: .scoutDB, body: body)
                }
                await RequestGate.shared.leave()
                return value
            } catch {
                await RequestGate.shared.leave()
                throw error
            }
        }
    }
}

extension CKOperation.Configuration {
    static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
