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
        #expect([1, 2, 3, 4, 5].chunked(into: 2) == [[1, 2], [3, 4], [5]])
        #expect([1, 2, 3].chunked(into: 5) == [[1, 2, 3]])
        #expect([Int]().chunked(into: 3) == [])
    }

    @Test("A non-positive size does not trap and yields one unbounded chunk")
    func nonPositiveSize() {
        // stride(by:) would trap on a zero or negative step; instead the whole
        // array comes back as a single chunk, and an empty array as no chunks.
        #expect([1, 2, 3].chunked(into: 0) == [[1, 2, 3]])
        #expect([1, 2, 3].chunked(into: -1) == [[1, 2, 3]])
        #expect([Int]().chunked(into: 0) == [])
    }
}
