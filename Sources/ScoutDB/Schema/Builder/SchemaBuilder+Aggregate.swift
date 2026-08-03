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
    /// ```swift
    /// try await store.schema("visit")
    ///     .field("page", .string, .ungrouped)
    ///     .count(by: "page")
    ///     .create()
    /// ```
    ///
    public func count(by group: String? = nil, shards: Int? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(by: group, shards: shards))
        return builder
    }

    /// Keeps a running total of the field, which `average` derives from.
    ///
    /// The total is folded into the cell on every write, so reading it costs a
    /// request whatever the entity grows to. `shards` spreads one hot cell over
    /// several records when many devices write the same group at once —
    /// readers sum the shards, so declare it only where the contention is real.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("amount", .double)
    ///     .sum("amount", by: "product_id")
    ///     .create()
    ///
    /// let revenue = try await store.query("purchase").totals("amount", metric: .sum, group: "product_id")
    /// ```
    ///
    public func sum(_ field: String, by group: String? = nil, shards: Int? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(metric: .sum, of: field, by: group, shards: shards))
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
    public func min(_ field: String, by group: String? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(metric: .min, of: field, by: group))
        return builder
    }

    /// Keeps the largest value of the field a cell has seen, standing after a
    /// removal as in ``min(_:by:)``.
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
    public func max(_ field: String, by group: String? = nil) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(metric: .max, of: field, by: group))
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
    public func histogram(of field: String, bounds: [Double]) -> Self {
        var builder = self
        builder.aggregates.append(AggregateDefinition(histogramOf: field, bounds: bounds))
        return builder
    }
}
