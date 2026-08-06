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
    /// count aggregate over the same grouping, and needs both declared. The
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
        let total = try await total

        guard metric == .average, field != nil else {
            return try await total.rows(field: field, metric: metric, group: group)
        }
        return try await total.averages(field: field, group: group)
    }
}

public struct AggregateTotal: Equatable, Sendable {
    public let group: String
    public let value: Double
}

extension AggregateTotal: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.group < rhs.group
    }
}
