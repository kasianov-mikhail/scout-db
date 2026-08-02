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

        builder.aggregates.append(
            AggregateDefinition(
                name: Self.name(nil, of: nil, by: group),
                groupBy: group,
                shards: shards
            )
        )

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
    /// let revenue = try await store.query("purchase").totals("amount", by: "product_id")
    /// ```
    ///
    public func sum(_ field: String, by group: String? = nil, shards: Int? = nil) -> Self {
        var builder = self

        builder.aggregates.append(
            AggregateDefinition(
                name: Self.name("sum", of: field, by: group),
                groupBy: group,
                sum: field,
                shards: shards
            )
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
    public func min(_ field: String, by group: String? = nil) -> Self {
        var builder = self

        builder.aggregates.append(
            AggregateDefinition(
                name: Self.name("min", of: field, by: group),
                groupBy: group,
                min: field
            )
        )

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

        builder.aggregates.append(
            AggregateDefinition(
                name: Self.name("max", of: field, by: group),
                groupBy: group,
                max: field
            )
        )

        return builder
    }
}
