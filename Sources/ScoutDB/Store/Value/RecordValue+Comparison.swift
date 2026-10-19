//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    func satisfies(op: Operator, other: RecordValue) -> Bool {
        let comparable =
            switch (self, other) {
            case (.string, .string), (.date, .date):
                true
            default:
                scalar != nil && other.scalar != nil
            }
        guard comparable else {
            return false
        }

        return switch (op, Self.rank(lhs: self, rhs: other)) {
        case (.greaterThan, .orderedDescending), (.lessThan, .orderedAscending):
            true
        case (.greaterThanOrEquals, .orderedDescending), (.greaterThanOrEquals, .orderedSame):
            true
        case (.lessThanOrEquals, .orderedAscending), (.lessThanOrEquals, .orderedSame):
            true
        default:
            false
        }
    }
}
