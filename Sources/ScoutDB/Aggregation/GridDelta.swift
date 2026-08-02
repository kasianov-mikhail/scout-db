//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct GridDelta {
    var count: Int64 = 0
    var kind: Metric?
    var value: Double?

    mutating func merge(_ other: GridDelta) {
        count += other.count

        guard let kind = other.kind else {
            return
        }
        self.kind = kind

        if let total = other.value {
            value = value.map { kind.combine($0, total) } ?? total
        }
    }

    func isNoop() -> Bool {
        guard count == 0 else {
            return false
        }
        guard let kind, let total = value else {
            return true
        }
        return kind.isReversible && total == 0
    }
}
