//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// Retries an operation the server rate-limited, sleeping out the
/// server-suggested `retryAfterSeconds` between attempts.
///
/// Only `requestRateLimited` and `zoneBusy` retry, and only while the error
/// carries a retry-after hint; anything else — and the final failure once
/// `maxRetry` attempts are spent — propagates unchanged.
///
func withRateLimitRetry<R>(maxRetry: Int = 3, operation: () async throws -> R) async throws -> R {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch let error as CKError where [.requestRateLimited, .zoneBusy].contains(error.code) {
            attempt += 1
            guard attempt < maxRetry, let delay = error.retryAfterSeconds else { throw error }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
