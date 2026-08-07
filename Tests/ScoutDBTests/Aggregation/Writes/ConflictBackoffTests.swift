//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Conflict backoff")
struct ConflictBackoffTests {
    private func samples(attempt: Int, count: Int = 200) -> [Double] {
        (0..<count).map { _ in conflictBackoff(attempt: attempt).seconds }
    }

    @Test("The window doubles with every attempt", arguments: [(1, 0.1), (2, 0.2), (3, 0.4), (4, 0.8), (5, 1.6)])
    func windowDoubles(attempt: Int, window: Double) {
        #expect(samples(attempt: attempt).allSatisfy { (0..<window).contains($0) })
    }

    @Test("The window stops doubling at two seconds")
    func windowCaps() {
        let delays = samples(attempt: 12)

        #expect(delays.allSatisfy { (0..<2.0).contains($0) })
        #expect(delays.contains { $0 > 1.6 })
    }

    @Test("A delay is spread over the whole window, not just its upper half")
    func jitterSpansTheWindow() throws {
        let delays = samples(attempt: 4)

        #expect(try #require(delays.min()) < 0.08)
        #expect(try #require(delays.max()) > 0.72)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
