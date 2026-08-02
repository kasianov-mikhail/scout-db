//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Orders the results by a field.
    ///
    /// Clauses apply in the order they are added, so the second breaks the ties
    /// of the first. Sorting is server-side over a slot-backed field; a payload
    /// field cannot be ordered on. A single clause over a scalar field is also
    /// what ``page(size:after:)`` pages by.
    ///
    /// ```swift
    /// try await store.query("purchase")
    ///     .sort("date", .reverse)
    ///     .sort("quantity")
    ///     .take(20)
    /// ```
    ///
    public func sort(_ field: String, _ order: SortOrder = .forward) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort(field: field, order: order))
        return builder
    }

    /// Caps how many records the query may return.
    ///
    /// The cap rides on the builder, so every terminal honors it — a ``take(_:)``
    /// asking for more gets the smaller of the two, and ``count()`` stops at it
    /// as well.
    ///
    /// ```swift
    /// let newest = try await store.query("purchase")
    ///     .sort("date", .reverse)
    ///     .limit(10)
    ///     .take(50)   // ten come back
    /// ```
    ///
    public func limit(_ count: Int) -> Self {
        var builder = self
        builder.ceiling = count
        return builder
    }
}
