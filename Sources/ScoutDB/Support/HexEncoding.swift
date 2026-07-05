//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hex encoding of the bytes — the shared spelling for digest and
    /// MAC record ids across the store.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// The shared recipe for content-derived record ids.
///
/// Components joined with "|", SHA256, lowercase hex. A persistence-format
/// invariant — every stable record id (natural uuids, grid slots) must go
/// through this one spelling.
func contentDigest(of components: [String]) -> String {
    SHA256.hash(data: Data(components.joined(separator: "|").utf8)).hexString
}
