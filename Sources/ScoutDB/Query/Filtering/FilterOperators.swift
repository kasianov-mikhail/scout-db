//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

infix operator ~~ : ComparisonPrecedence
infix operator =~ : ComparisonPrecedence

/// Matches the records whose field equals the value.
///
/// The server answers it directly when the field lives in a slot. Watch the one
/// collision: `String == String` is Swift's own equality, so a bare literal on
/// the right resolves to `Bool` rather than an expression — write string
/// equality as `.filter("field", .equals, "value")`, or give the value a type
/// the operator can see, as `.string(…)` does.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("quantity" == 5)
///     .take(20)
/// ```
///
public func == (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .equals, value: value))
}

/// Matches the records whose field holds anything but the value.
///
/// The server answers it directly over a slot-backed field, and the client after
/// decoding otherwise. Either way a record missing the field does not match:
/// the comparison needs a value to fail against.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("state" != 0)
///     .take(20)
/// ```
///
public func != (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .notEquals, value: value))
}

/// Matches the records whose field is greater than the value.
///
/// Comparisons are server-side over a slot-backed scalar. On an integer field
/// bounded by `min` and `max`, a threshold can be answered off the grid without
/// reading records at all — see ``QueryBuilder/count()``.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("quantity" > 5)
///     .take(20)
/// ```
///
public func > (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .greaterThan, value: value))
}

/// Matches the records whose field is greater than or equal to the value.
///
/// Paired with `<` it spells a half-open range, the shape a range lands on
/// cleanly: `"quantity" >= 2 && "quantity" < 10`.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("quantity" >= 5)
///     .take(20)
/// ```
///
public func >= (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .greaterThanOrEquals, value: value))
}

/// Matches the records whose field is less than the value.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("amount" < 100)
///     .take(20)
/// ```
///
public func < (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .lessThan, value: value))
}

/// Matches the records whose field is less than or equal to the value.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("amount" <= 100)
///     .take(20)
/// ```
///
public func <= (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .lessThanOrEquals, value: value))
}

/// Matches a substring of a string field, or membership in a list field.
///
/// What it means follows the field's type: over a `.string` it is a substring
/// search, run on the client after decoding, and over a `.stringList` it asks
/// server-side whether the list carries the value.
///
/// ```swift
/// try await store.query("post")
///     .filter("tags" ~~ "swift")
///     .take(20)
/// ```
///
public func ~~ (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .contains, value: value))
}

/// Matches the records whose string field starts with the value.
///
/// Server-side, over a slot-backed string field.
///
/// ```swift
/// try await store.query("cart")
///     .filter("name" =~ "cart_")
///     .take(20)
/// ```
///
public func =~ (field: String, value: RecordValue) -> FilterExpression {
    FilterExpression(Filter(field: field, op: .beginsWith, value: value))
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
