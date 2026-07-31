//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// How many calls a database double served, split by kind.
///
/// Tests that guard a request budget read the tally rather than the records:
/// a path that folds a batch into one write and one that writes per record
/// leave the same rows behind.
///
public struct RequestTally: Sendable {
    public enum Kind: String, Sendable {
        case query, continuation, save, modify, conditionalSave
        case fetch
    }

    public private(set) var counts: [Kind: Int] = [:]

    /// How many records the calls carried — results for reads, inputs for writes.
    public private(set) var records = 0

    /// How many calls threw.
    ///
    /// A conditional save that reports a per-record failure in its results
    /// settles as a success.
    ///
    public private(set) var failures = 0

    public init() {}

    public var total: Int {
        counts.values.reduce(0, +)
    }

    public subscript(kind: Kind) -> Int {
        counts[kind] ?? 0
    }

    mutating func add(_ kind: Kind, carrying carried: Int) {
        counts[kind, default: 0] += 1
        records += carried
    }

    mutating func fail(_ kind: Kind) {
        counts[kind, default: 0] += 1
        failures += 1
    }
}
