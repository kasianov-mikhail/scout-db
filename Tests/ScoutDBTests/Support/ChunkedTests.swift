//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Testing

@testable import ScoutDB

@Suite("Array chunking")
struct ChunkedTests {
    @Test("Positive sizes chunk as expected")
    func positiveSizes() {
        #expect([1, 2, 3, 4, 5].chunked(size: 2) == [[1, 2], [3, 4], [5]])
        #expect([1, 2, 3].chunked(size: 5) == [[1, 2, 3]])
        #expect([Int]().chunked(size: 3) == [])
    }

    @Test("A non-positive size does not trap and yields one unbounded chunk")
    func nonPositiveSize() {
        #expect([1, 2, 3].chunked(size: 0) == [[1, 2, 3]])
        #expect([1, 2, 3].chunked(size: -1) == [[1, 2, 3]])
        #expect([Int]().chunked(size: 0) == [])
    }
}
