//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

final class PerfRecorder: DatabaseObserver, @unchecked Sendable {
    struct Tally: Sendable {
        var counts: [DatabaseOperation.Kind: Int] = [:]
        var records = 0
        var failures = 0

        var total: Int {
            counts.values.reduce(0, +)
        }

        subscript(kind: DatabaseOperation.Kind) -> Int {
            counts[kind] ?? 0
        }
    }

    private let lock = NSLock()
    private var tally = Tally()

    func record(_ operation: DatabaseOperation) {
        lock.withLock {
            tally.counts[operation.kind, default: 0] += 1
            tally.records += operation.recordCount
            if operation.error != nil {
                tally.failures += 1
            }
        }
    }

    func reset() {
        lock.withLock { tally = Tally() }
    }

    var snapshot: Tally {
        lock.withLock { tally }
    }
}
