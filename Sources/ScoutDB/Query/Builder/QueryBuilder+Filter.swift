//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Narrows the query to the records the filter matches.
    ///
    /// Takes a single filter or a whole expression of them, and `AND`-s it with
    /// whatever the builder already carries — so a disjunction narrows the same
    /// way a plain filter does. Each alternative of the result costs one server
    /// query, so what an expression multiplies out to is what it costs.
    ///
    /// ```swift
    /// try await store.query("log")
    ///     .filter("count" > 5)
    ///     .filter("level" == "error" || ("level" == "warning" && "count" > 10))
    ///     .take(50)
    /// ```
    ///
    public func filter(_ expression: FilterExpression) -> Self {
        var builder = self
        builder.alternatives = (FilterExpression(alternatives) && expression).alternatives
        return builder
    }

    /// Narrows the query with a filter spelled out field by field.
    ///
    /// The same clause as ``filter(_:)`` for the matches the operators do not
    /// spell — `beginsWith`, `contains`, `in`, `search`.
    ///
    /// ```swift
    /// try await store.query("place")
    ///     .filter("name", .beginsWith, "Cafe")
    ///     .filter("tags", .contains, "coffee")
    ///     .take(20)
    /// ```
    ///
    public func filter(_ field: String, _ method: Operator, _ value: RecordValue) -> Self {
        filter(FilterExpression(EntityStore.Filter(field: field, op: method, value: value)))
    }
}
