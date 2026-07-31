//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

actor RequestGate {
    static let shared = RequestGate()

    private var limit: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 8) {
        self.limit = Swift.max(1, limit)
    }

    func enter() async {
        guard inFlight >= limit else {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        guard waiting.count > 0 else {
            inFlight = Swift.max(0, inFlight - 1)
            return
        }
        waiting.removeFirst().resume()
    }

    func setLimit(_ count: Int) {
        limit = Swift.max(1, count)
        while inFlight < limit, waiting.count > 0 {
            inFlight += 1
            waiting.removeFirst().resume()
        }
    }

    var currentLimit: Int {
        limit
    }
}
