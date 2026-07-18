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
/// Components escaped, joined with "|", SHA256, lowercase hex. A
/// persistence-format invariant — every stable record id (natural uuids, grid
/// slots) must go through this one spelling.
///
/// Escaping "\" and "|" before the join keeps the separator unambiguous, so a
/// component that itself contains "|" cannot masquerade as a boundary:
/// `["a|b", "c"]` and `["a", "b|c"]` must hash differently. Components free of
/// "|" and "\" encode byte-for-byte as an unescaped join would, so ids minted
/// before this escaping stay valid.
func contentDigest(of components: [String]) -> String {
    let escaped = components.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }
    return SHA256.hash(data: Data(escaped.joined(separator: "|").utf8)).hexString
}
