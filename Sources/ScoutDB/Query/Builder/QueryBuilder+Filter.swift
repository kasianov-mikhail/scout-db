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
        let added = expression.alternatives
        var builder = self
        builder.alternatives = alternatives.flatMap { branch in added.map { branch + $0 } }
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
    public func filter(_ field: String, _ method: EntityStore.Match, _ value: RecordValue) -> Self {
        let filter = EntityStore.Filter(field: field, op: method, value: value)
        var builder = self
        builder.alternatives = alternatives.map { $0 + [filter] }
        return builder
    }

    /// Excludes the records the expression matches — a `NOT` over the whole of
    /// it.
    ///
    /// The negation is pushed down to the matches themselves by De Morgan, so
    /// excluding a disjunction requires both sides to fail, while excluding a
    /// conjunction admits a record failing either — and the second costs an
    /// alternative per match.
    ///
    /// A comparison, equality or `in` over an always-present slot field —
    /// `.required`, or carrying a `.defaultValue` — is sent to the server as its
    /// complementary operator; every other negation is evaluated client-side
    /// after decoding, so a record missing the field is kept. `search` cannot
    /// be negated.
    ///
    /// ```swift
    /// try await store.query("purchase")
    ///     .exclude("status" == "archived" || "status" == "draft")
    ///     .take(20)
    /// ```
    ///
    public func exclude(_ expression: FilterExpression) -> Self {
        let added = expression.negated.alternatives
        var builder = self
        builder.alternatives = alternatives.flatMap { branch in added.map { branch + $0 } }
        return builder
    }

    /// Excludes the records the filter matches, spelled out field by field.
    ///
    /// The same negation as ``exclude(_:)`` for the matches the operators do not
    /// spell — and the only way to negate them at all, since `beginsWith`,
    /// `contains` and `search` have no complementary
    /// operator to write positively.
    ///
    /// ```swift
    /// try await store.query("post")
    ///     .exclude("tags", .contains, "draft")
    ///     .take(20)
    /// ```
    ///
    public func exclude(_ field: String, _ method: EntityStore.Match, _ value: RecordValue) -> Self {
        var negated = EntityStore.Filter(field: field, op: method, value: value)
        negated.negated = true
        var builder = self
        builder.alternatives = alternatives.map { $0 + [negated] }
        return builder
    }
}
