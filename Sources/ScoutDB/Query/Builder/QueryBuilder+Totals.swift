//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// One total per group, folded across every record the grid counts.
    ///
    /// One row per group: the count, the metric's value, and the `average`
    /// derived from them. Without a `field` the rows count alone. `metric`
    /// picks which declared aggregate answers the read, so a field two
    /// aggregates fold — a `min` and a `max` of the same amount — stays
    /// reachable either way. The only
    /// clause a grid read can honor is an
    /// equality filter on the grouping field, which narrows it to that group
    /// server-side; any other filter throws rather than being quietly dropped.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .totals("amount", by: "product_id")
    /// // [AggregateTotal(group: "sku-42", count: 48211, value: 481628.9), ...]
    /// ```
    ///
    public func totals(
        _ field: String? = nil, metric: Metric = .sum, by group: String? = nil
    ) async throws -> [AggregateTotal] {
        try await total.rows(
            field: field,
            metric: metric,
            group: group
        )
    }
}

public struct AggregateTotal: Equatable, Sendable {
    public let group: String
    public let count: Int
    public let value: Double?

    public var average: Double? {
        guard let value, count > 0 else {
            return nil
        }
        return value / Double(count)
    }
}

extension AggregateTotal: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.group < rhs.group
    }
}
