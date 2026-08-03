//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension FilterPlan {
    struct Bounds: Equatable {
        var field: String
        var lower: Double?
        var upper: Double?

        func narrowed(by filter: ClientFilter) -> Self? {
            guard filter.field == field else {
                return nil
            }

            return switch filter.op {
            case .greaterThanOrEquals where lower == nil:
                filter.value.scalar.map { Self(field: field, lower: $0, upper: upper) }
            case .greaterThan where lower == nil:
                filter.value.next.map { Self(field: field, lower: $0, upper: upper) }
            case .lessThan where upper == nil:
                filter.value.scalar.map { Self(field: field, lower: lower, upper: $0) }
            case .lessThanOrEquals where upper == nil:
                filter.value.next.map { Self(field: field, lower: lower, upper: $0) }
            default:
                nil
            }
        }
    }
}

extension RecordValue {
    fileprivate var next: Double? {
        guard case .int(let value) = self, value < .max else {
            return nil
        }
        return Double(value + 1)
    }
}
