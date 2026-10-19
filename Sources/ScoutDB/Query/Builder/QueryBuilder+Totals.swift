//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// One total per group, folded across every hour the vector holds.
    ///
    /// One row per group, carrying the value the aggregate folds: the metric
    /// over the field, or the count of records when no `field` is named.
    /// `metric` picks which declared aggregate answers the read, so a field two
    /// aggregates fold — a `min` and a `max` of the same amount — stays
    /// reachable either way; `.average` divides the `sum` aggregate by the
    /// count aggregate over the same grouping, and needs both declared, over a
    /// field that is `required` or carries a default — the count divides in
    /// every record of the group, so one missing the field would pull the mean
    /// down rather than stay out of it. The
    /// only clause a vector read can honor is an equality filter on the grouping
    /// field, which narrows it to that group server-side; any other filter
    /// throws rather than being quietly dropped.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .totals("amount", metric: .sum, group: "product_id")
    /// // [AggregateTotal(group: "sku-42", value: 481628.9), ...]
    /// ```
    ///
    public func totals(_ field: String? = nil, metric: Metric, group: String? = nil) async throws -> [AggregateTotal] {
        try await totals(field, metric: metric, groups: group.map { [$0] } ?? [])
    }

    /// One total per combination of the grouping fields, read off an aggregate
    /// declared over the same fields, in the same order.
    ///
    /// ``AggregateTotal/groupValues`` splits a total's group back into the
    /// values of the fields. A vector read over several fields honors no filter.
    ///
    /// ```swift
    /// let sessions = try await store.query("session").totals(metric: .sum, groups: ["channel", "app_version"])
    /// ```
    ///
    public func totals(_ field: String? = nil, metric: Metric, groups: [String]) async throws -> [AggregateTotal] {
        let total = try await total

        guard metric == .average, let field else {
            return try await total.rows(field: field, metric: metric, groups: groups)
        }
        return try await total.averages(field: field, groups: groups)
    }
}

public struct AggregateTotal: Equatable, Sendable {
    public let group: String
    public let value: Double

    /// The values of the grouping fields, in the order a read over several
    /// fields named them.
    ///
    /// Read it only off totals over several fields: a single field's value is
    /// the whole ``group`` as it is.
    ///
    public var groupValues: [String] {
        group.groupValues
    }
}

extension AggregateTotal: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.group < rhs.group
    }
}
