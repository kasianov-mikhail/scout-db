//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation

private let hexDigits: [Character] = Array("0123456789abcdef")

extension Sequence where Element == UInt8 {
    var hexString: String {
        var encoded = ""
        encoded.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            encoded.append(hexDigits[Int(byte >> 4)])
            encoded.append(hexDigits[Int(byte & 0x0F)])
        }
        return encoded
    }
}

func contentDigest(of components: [String]) -> String {
    let escaped = components.map { component in
        guard escapesSeparators([component]) else { return component }
        return component.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }
    return SHA256.hash(data: Data(escaped.joined(separator: "|").utf8)).hexString
}

func escapesSeparators(_ components: [String]) -> Bool {
    components.contains { $0.contains(where: { $0 == "\\" || $0 == "|" }) }
}
