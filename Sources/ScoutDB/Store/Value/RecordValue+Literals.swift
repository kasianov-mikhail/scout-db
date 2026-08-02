//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue: ExpressibleByStringLiteral {
    /// Reads a string literal as a ``RecordValue/string(_:)``.
    ///
    /// Note that a bare string literal on the right of `==` resolves to Swift's
    /// own `String == String` instead, so spell string equality out as
    /// `.filter("field", .equals, "value")`.
    ///
    /// ```swift
    /// let values: [String: RecordValue] = ["name": "cart_1"]
    ///
    /// try await store.query("cart")
    ///     .filter("name", .beginsWith, "cart_")
    ///     .take(20)
    /// ```
    ///
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension RecordValue: ExpressibleByIntegerLiteral {
    /// Reads an integer literal as an ``RecordValue/int(_:)``, widened to 64 bits.
    ///
    /// ```swift
    /// let values: [String: RecordValue] = ["quantity": 5]
    ///
    /// try await store.query("purchase")
    ///     .filter("quantity" > 5)
    ///     .take(20)
    /// ```
    ///
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension RecordValue: ExpressibleByFloatLiteral {
    /// Reads a floating-point literal as a ``RecordValue/double(_:)``.
    ///
    /// ```swift
    /// let values: [String: RecordValue] = ["total": 9.99]
    ///
    /// try await store.query("purchase")
    ///     .filter("total" <= 9.99)
    ///     .take(20)
    /// ```
    ///
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension RecordValue: ExpressibleByBooleanLiteral {
    /// Reads a boolean literal as an ``RecordValue/int(_:)`` holding 1 or 0.
    ///
    /// There is no boolean case: a flag is stored as an integer field, and
    /// `true` and `false` are shorthand for its two values.
    ///
    /// ```swift
    /// let values: [String: RecordValue] = ["paid": true]
    ///
    /// try await store.query("purchase")
    ///     .filter("paid", .equals, true)
    ///     .take(20)
    /// ```
    ///
    public init(booleanLiteral value: Bool) {
        self = .int(value ? 1 : 0)
    }
}
