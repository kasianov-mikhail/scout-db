//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    /// Counts the records per value of the grouping field.
    ///
    /// Creation already counts every groupable field, so this is for the grids
    /// nothing infers — a count over a field marked `.ungrouped`, or one
    /// spread over shards. On an `update()` an aggregate joins the ones the
    /// entity already keeps, and one of the same shape replaces its
    /// predecessor.
    ///
    /// A cell is an hour: the grid keeps one record per group and week, holding
    /// the 168 hours of that week, so the count is filed under the hour the
    /// record belongs to. `at` names the timestamp field that hour is read
    /// from; without it the hour is the one the write lands in, and a later
    /// rewrite of the same record reverses out of the hour it is rewritten in
    /// rather than the one it first landed in.
    ///
    /// ```swift
    /// try await store.schema("visit")
    ///     .field("page", .string, .ungrouped)
    ///     .field("seen_at", .timestamp)
    ///     .count(by: "page", at: "seen_at")
    ///     .create()
    /// ```
    ///
    public func count(by group: String? = nil, at date: String? = nil, shards: Int? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(by: group, at: date, shards: shards))
        return builder
    }

    /// Keeps a running total of the field, which `average` divides.
    ///
    /// The total is folded into the hour's cell on every write, so reading it
    /// costs a request whatever the entity grows to. A cell holds one number —
    /// the total, never a count beside it — so `average` divides this
    /// aggregate by the count aggregate over the same grouping, and reads it
    /// only where both are declared. `at` dates the cell as in
    /// ``count(by:at:shards:)``. `shards` spreads one hot cell over several
    /// records when many devices write the same group at once — readers sum
    /// the shards, so declare it only where the contention is real.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("amount", .double)
    ///     .field("date", .timestamp)
    ///     .sum("amount", by: "product_id", at: "date")
    ///     .create()
    ///
    /// let revenue = try await store.query("purchase").totals("amount", metric: .sum, group: "product_id")
    /// ```
    ///
    public func sum(_ field: String, by group: String? = nil, at date: String? = nil, shards: Int? = nil) -> Self {
        var builder = self
        builder.aggregates.append(
            AggregateDefinition(metric: .sum, of: field, by: group, at: date, shards: shards)
        )
        return builder
    }

    /// Keeps the smallest value of the field a cell has seen.
    ///
    /// The cell holds a running extremum, so removing the record that set it
    /// leaves the value standing — a read served by the aggregate answers with what
    /// the group once reached, not what it holds now.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("amount", .double)
    ///     .min("amount", by: "product_id")
    ///     .create()
    /// ```
    ///
    public func min(_ field: String, by group: String? = nil, at date: String? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(metric: .min, of: field, by: group, at: date))
        return builder
    }

    /// Keeps the largest value of the field a cell has seen, standing after a
    /// removal as in ``min(_:by:at:)``.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("amount", .double)
    ///     .max("amount", by: "product_id")
    ///     .create()
    ///
    /// let peak = try await store.query("purchase").max("amount")
    /// ```
    ///
    public func max(_ field: String, by group: String? = nil, at date: String? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(metric: .max, of: field, by: group, at: date))
        return builder
    }

    /// Counts the field's values into the buckets ``QueryBuilder/percentile(_:of:)``
    /// reads off; the bounds are exclusive upper ones, ascending.
    ///
    /// A value lands in the first bucket it falls under, and whatever reaches
    /// the last bound lands in an overflow bucket past it — so `n` bounds make
    /// `n + 1` buckets, each its own grid record. The percentile is
    /// interpolated within the bucket it falls in, so the answer is as fine as
    /// the bounds are; they are yours to pick, because only you know the
    /// distribution. A record missing the field is counted nowhere.
    ///
    /// The bucket is the grouping, so a histogram takes neither `by:` nor a
    /// metric. Mark the field `.ungrouped` unless you also want a count per
    /// distinct value of it.
    ///
    /// ```swift
    /// try await store.schema("request")
    ///     .field("latency", .double, .ungrouped)
    ///     .histogram(of: "latency", bounds: [10, 25, 50, 100, 250, 500, 1_000])
    ///     .create()
    ///
    /// let p95 = try await store.query("request").percentile(0.95, of: "latency")
    /// ```
    ///
    public func histogram(of field: String, bounds: [Double], at date: String? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(histogramOf: field, bounds: bounds, at: date))
        return builder
    }
}
