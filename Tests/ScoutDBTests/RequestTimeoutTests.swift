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
}
