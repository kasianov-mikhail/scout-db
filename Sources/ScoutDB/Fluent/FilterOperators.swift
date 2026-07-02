//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

infix operator ~~ : ComparisonPrecedence
infix operator =~ : ComparisonPrecedence

/// Builds an equality filter: `.filter("quantity" == 5)`.
///
/// String comparisons resolve to `String == String` first, so spell string
/// equality as `.filter("field", .equals, "value")` instead.
///
public func == (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .equals, value: value)
}

/// Builds an inequality filter: `.filter("state" != 0)`.
public func != (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .notEquals, value: value)
}

/// Builds a greater-than filter: `.filter("quantity" > 5)`.
public func > (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .greaterThan, value: value)
}

/// Builds a greater-than-or-equal filter.
public func >= (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .greaterThanOrEquals, value: value)
}

/// Builds a less-than filter.
public func < (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .lessThan, value: value)
}

/// Builds a less-than-or-equal filter.
public func <= (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .lessThanOrEquals, value: value)
}

/// Builds a contains filter: substring on strings, membership on lists.
public func ~~ (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .contains, value: value)
}

/// Builds a prefix filter: `.filter("name" =~ "cart_")`.
public func =~ (field: String, value: RecordValue) -> UniversalStore.Filter {
    UniversalStore.Filter(field: field, op: .beginsWith, value: value)
}

extension RecordValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension RecordValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension RecordValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension RecordValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .int(value ? 1 : 0)
    }
}
