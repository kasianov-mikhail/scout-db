//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension [String] {
    var groupKey: String {
        count == 1 ? self[0] : map(\.escapedGroupValue).joined(separator: "|")
    }
}

extension String {
    var groupValues: [String] {
        var values: [String] = []
        var current = ""
        var escaped = false

        for character in self {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        return values + [current]
    }

    fileprivate var escapedGroupValue: String {
        replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }
}
