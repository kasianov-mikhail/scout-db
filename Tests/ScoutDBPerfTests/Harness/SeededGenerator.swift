//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A SplitMix64 generator, so every corpus is a pure function of its seed.
///
/// Request counts are only comparable between runs when the data they run over
/// is identical, and `SystemRandomNumberGenerator` cannot promise that.
///
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<bound`, biased only as much as a modulo reduction is.
    mutating func index(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// A double in `0..<1`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[index(below: values.count)]
    }

    /// An index into `count` buckets, skewed so the first buckets take most of
    /// the draws — the shape of orders per customer, or events per device.
    mutating func skewed(below count: Int) -> Int {
        let biased = unit() * unit()
        return Swift.min(count - 1, Int(biased * Double(count)))
    }
}
