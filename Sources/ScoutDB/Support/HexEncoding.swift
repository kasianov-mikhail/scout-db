//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hex encoding of the bytes — the shared spelling for digest and
    /// MAC record ids across the store.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
