//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

// A backstop above CloudKit's own 10s request/resource timeout: a write can stall
// server-side without that timeout firing, so this cancels the operation and
// unblocks the caller rather than letting a single stuck call hang forever.
let requestTimeout: Duration = .seconds(30)

extension CKDatabase {
    /// Applies ScoutDB's CloudKit request policy: a bounded operation
    /// configuration, a backstop timeout, and retries when the server
    /// rate-limits the request.
    @discardableResult func throttled<R>(body: @Sendable @escaping (CKDatabase) async throws -> R) async throws -> R {
        try await withRequestTimeout(requestTimeout) {
            try await withRateLimitRetry {
                try await self.configuredWith(configuration: .scoutDB, body: body)
            }
        }
    }
}

extension CKOperation.Configuration {
    /// The configuration for every ScoutDB request.
    static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
