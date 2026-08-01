//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

private func retryDelay(attempt: Int, suggested: Double?) -> Double {
    if let suggested {
        return suggested
    }
    let window = 0.5 * pow(2, Double(Swift.max(0, attempt - 1)))
    return window * (0.5 + 0.5 * Double.random(in: 0..<1))
}

func withRateLimitRetry<R>(
    maxRetry: Int = 3,
    operation: () async throws -> R
) async throws -> R {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch let error as CKError where [.requestRateLimited, .zoneBusy].contains(error.code) {
            attempt += 1
            guard attempt < maxRetry else {
                throw error
            }
            let delay = retryDelay(attempt: attempt, suggested: error.retryAfterSeconds)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
