//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    static func rank(_ lhs: RecordValue?, _ rhs: RecordValue?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            .orderedSame
        case (nil, _):
            .orderedAscending
        case (_, nil):
            .orderedDescending
        case (let lhs?, let rhs?):
            rank(lhs, rhs)
        }
    }

    private static func rank(_ lhs: RecordValue, _ rhs: RecordValue) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)):
            return order(lhs, rhs)
        case (.date(let lhs), .date(let rhs)):
            return order(lhs, rhs)
        default:
            guard let lhs = lhs.scalar, let rhs = rhs.scalar else {
                return .orderedSame
            }
            return order(lhs, rhs)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
