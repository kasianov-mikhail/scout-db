//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

func retryDelay(attempt: Int, suggested: Double?, base: Double = 0.5, random: () -> Double = { Double.random(in: 0..<1) }) -> Double {
    if let suggested {
        return suggested
    }
    let window = base * pow(2, Double(Swift.max(0, attempt - 1)))
    return window * (0.5 + 0.5 * random())
}

func withRateLimitRetry<R>(
    maxRetry: Int = 3, sleep: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
    operation: () async throws -> R
) async throws -> R {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch let error as CKError where [.requestRateLimited, .zoneBusy].contains(error.code) {
            attempt += 1
            guard attempt < maxRetry else { throw error }
            try await sleep(retryDelay(attempt: attempt, suggested: error.retryAfterSeconds))
        }
    }
}
