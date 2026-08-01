//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct CellDelta {
    var count: Int64 = 0
    var kind: Metric?
    var value: Double?
    var removed: Double?

    mutating func merge(_ other: CellDelta) {
        count += other.count

        guard let kind = other.kind else {
            return
        }
        self.kind = kind

        if let total = other.value {
            value = value.map { kind.combine($0, total) } ?? total
        }
        if let total = other.removed {
            removed = removed.map { kind.combine($0, total) } ?? total
        }
    }

    func isNoop() -> Bool {
        guard count == 0 else {
            return false
        }
        guard let kind, let total = value else {
            return true
        }
        guard kind != .sum else {
            return total == 0
        }
        guard let removed else {
            return false
        }
        return kind.combine(removed, total) == removed
    }
}
