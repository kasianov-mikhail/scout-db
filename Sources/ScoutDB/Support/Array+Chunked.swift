//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        // stride(by:) traps on a non-positive step, so a zero or negative size
        // would crash instead of just declining to chunk. Treat it as "one
        // unbounded chunk" — the whole array — rather than a precondition failure.
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
