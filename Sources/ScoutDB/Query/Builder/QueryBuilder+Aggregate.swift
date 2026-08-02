//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Runs the query and returns the number of matching records.
    ///
    /// A query a declared aggregate covers — filters limited to an equality,
    /// `in` list, or alternatives of them on the aggregate's grouping — is
    /// answered from the grid without scanning records. A threshold on an
    /// integer field an aggregate groups by is
    /// answered from the grid too when the field's `min` and `max` bound it to
    /// a domain the range can name value by value; a strict threshold counts as
    /// the half-open one it equals, so `> 15` reads as `>= 16`. Every other
    /// query scans the matching records.
    ///
    /// ```swift
    /// let paid = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .count()
    /// ```
    ///
    public func count() async throws -> Int {
        if let folded = try await store.folder(entity: entity, any: alternatives)?.fold(of: nil, by: nil) {
            return Swift.min(
                folded.values.reduce(0) { $0 + $1.count },
                ceiling ?? Int.max
            )
        }

        return try await ReadOperation(
            store: store,
            entity: entity,
            sort: sorts,
            limit: ceiling
        )
        .read(any: alternatives)
        .count
    }

    /// Sums a numeric field across the matching records.
    ///
    /// The fold is answered from an aggregate's grid when one covers the query
    /// and reads records otherwise. Records missing the field contribute
    /// nothing; with no match at all the sum is zero.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .sum("amount")
    /// ```
    ///
    public func sum(_ field: String) async throws -> Double {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field
        )
        .value(fold: .sum) ?? 0
    }

    /// The smallest value of a numeric field across the matching records.
    ///
    /// `nil` when nothing matches or no match carries the field. Answered from
    /// a grid keeping that extremum when one covers the query, and by reading
    /// the field otherwise.
    ///
    /// ```swift
    /// let cheapest = try await store.query("purchase")
    ///     .filter("product_id" == "sku-42")
    ///     .min("amount")
    /// ```
    ///
    public func min(_ field: String) async throws -> Double? {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field
        )
        .value(fold: .min)
    }

    /// The largest value of a numeric field across the matching records.
    ///
    /// `nil` when nothing matches or no match carries the field. Answered from
    /// a grid keeping that extremum when one covers the query, and by reading
    /// the field otherwise.
    ///
    /// ```swift
    /// let biggest = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .max("amount")
    /// ```
    ///
    public func max(_ field: String) async throws -> Double? {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field
        )
        .value(fold: .max)
    }

    /// The mean of a numeric field across the matching records.
    ///
    /// `nil` when nothing matches or no match carries the field. A grid derives
    /// it from the running total and the count it already keeps, so no records
    /// are read when one covers the query.
    ///
    /// ```swift
    /// let basket = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .average("amount")
    /// ```
    ///
    public func average(_ field: String) async throws -> Double? {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field
        )
        .value(fold: .average)
    }

    /// Sums a numeric field per distinct value of the grouping field.
    ///
    /// One entry per value the grouping field takes among the matching records.
    /// An aggregate grouped by that field answers it without reading records;
    /// otherwise the query scans the matching records.
    ///
    /// ```swift
    /// let byProduct = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .sum("amount", by: "product_id")
    /// // ["sku-42": 1250.0, "sku-7": 310.0]
    /// ```
    ///
    public func sum(_ field: String, by group: String) async throws -> [String: Double] {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field,
            group: group
        )
        .values(fold: .sum)
    }

    /// The smallest value of a numeric field per distinct value of the grouping
    /// field.
    ///
    /// One entry per value the grouping field takes among the matching records;
    /// a group whose records all miss the folded field is left out.
    ///
    /// ```swift
    /// let cheapest = try await store.query("purchase")
    ///     .min("amount", by: "product_id")
    /// ```
    ///
    public func min(_ field: String, by group: String) async throws -> [String: Double] {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field,
            group: group
        )
        .values(fold: .min)
    }

    /// The largest value of a numeric field per distinct value of the grouping
    /// field.
    ///
    /// One entry per value the grouping field takes among the matching records;
    /// a group whose records all miss the folded field is left out.
    ///
    /// ```swift
    /// let peak = try await store.query("purchase")
    ///     .max("amount", by: "product_id")
    /// ```
    ///
    public func max(_ field: String, by group: String) async throws -> [String: Double] {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field,
            group: group
        )
        .values(fold: .max)
    }

    /// The mean of a numeric field per distinct value of the grouping field.
    ///
    /// One entry per value the grouping field takes among the matching records,
    /// each derived from that group's total and count.
    ///
    /// ```swift
    /// let basket = try await store.query("purchase")
    ///     .average("amount", by: "product_id")
    /// ```
    ///
    public func average(_ field: String, by group: String) async throws -> [String: Double] {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            field: field,
            group: group
        )
        .values(fold: .average)
    }

    /// Counts the matching records per distinct value of the grouping field.
    ///
    /// One entry per value the grouping field takes, read off the grid every
    /// creation builds over its groupable fields — so this costs one request
    /// however many records stand behind it, unless the query's shape falls
    /// outside what the grid can answer and it has to scan.
    ///
    /// ```swift
    /// let byStatus = try await store.query("purchase").count(by: "status")
    /// // ["placed": 128, "paid": 64]
    /// ```
    ///
    public func count(by group: String) async throws -> [String: Int] {
        try await AggregateOperation(
            store: store,
            entity: entity,
            branches: alternatives,
            group: group
        )
        .counts()
    }
}
