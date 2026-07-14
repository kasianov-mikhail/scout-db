//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import Testing

@testable import ScoutDB

@Suite("Rate limit retry")
struct RateLimitRetryTests {
    @Test("Retries after the server-suggested delay and returns the success")
    func retries() async throws {
        var calls = 0
        let result = try await withRateLimitRetry {
            calls += 1
            guard calls == 3 else { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 0.01]) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(calls == 3)
    }

    @Test("A rate limit without a retry-after hint fails immediately")
    func noHint() async {
        var calls = 0
        await #expect(throws: CKError.self) {
            try await withRateLimitRetry {
                calls += 1
                throw CKError(.requestRateLimited)
            }
        }
        #expect(calls == 1)
    }

    @Test("Exhausted retries surface the rate limit")
    func exhausted() async {
        var calls = 0
        await #expect(throws: CKError.self) {
            try await withRateLimitRetry {
                calls += 1
                throw CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.001])
            }
        }
        #expect(calls == 3)
    }

    @Test("Other errors pass through untouched")
    func passthrough() async {
        var calls = 0
        await #expect(throws: CKError.self) {
            try await withRateLimitRetry {
                calls += 1
                throw CKError(.notAuthenticated)
            }
        }
        #expect(calls == 1)
    }
}
