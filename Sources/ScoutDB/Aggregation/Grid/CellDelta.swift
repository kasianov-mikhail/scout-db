//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct CellDelta {
    var count: Int64 = 0
    var value: (kind: Metric, total: Double)?
    var squares: Double?
    var removed: (kind: Metric, total: Double)?

    func merging(_ other: CellDelta) -> CellDelta {
        var merged = self
        merged.count += other.count
        if let squares = other.squares {
            merged.squares = (merged.squares ?? 0) + squares
        }
        if let (kind, total) = other.value {
            merged.value = (kind, merged.value.map { kind.combine($0.total, total) } ?? total)
        }
        if let (kind, total) = other.removed {
            merged.removed = (kind, merged.removed.map { kind.combine($0.total, total) } ?? total)
        }
        return merged
    }

    func isNoop(recomputing: Bool) -> Bool {
        guard count == 0, (squares ?? 0) == 0 else {
            return false
        }
        guard !recomputing || removed == nil else {
            return false
        }
        guard let (kind, total) = value else {
            return true
        }
        guard kind != .sum else {
            return total == 0
        }
        guard let removed else {
            return false
        }
        return kind.combine(removed.total, total) == removed.total
    }
}
