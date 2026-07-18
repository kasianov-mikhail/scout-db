//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation
import Testing

@testable import ScoutDB

@Suite("Content digest")
struct DigestTests {
    @Test("Components containing the separator do not collide")
    func separatorDoesNotCollide() {
        // Without escaping, both of these join to "a|b|c" and share one id.
        #expect(contentDigest(of: ["a|b", "c"]) != contentDigest(of: ["a", "b|c"]))
        #expect(contentDigest(of: ["a", "b", "c"]) != contentDigest(of: ["a|b|c"]))
    }

    @Test("Components free of the separator keep their pre-escaping id")
    func cleanComponentsAreStable() {
        // Escaping only rewrites "|"/"\", so a clean join hashes exactly as an
        // unescaped join would — ids minted before the fix stay valid.
        let clean = ["order", "42", "sku-7"]
        let unescaped = SHA256.hash(data: Data(clean.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(contentDigest(of: clean) == unescaped)
    }
}
