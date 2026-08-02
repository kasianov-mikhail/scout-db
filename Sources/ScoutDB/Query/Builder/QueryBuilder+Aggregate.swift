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
        if let folded = try await store.folder(entity: entity, any: alternatives)?.fold(of: nil) {
            return Swift.min(folded.count, ceiling ?? Int.max)
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
        .value(metric: .sum) ?? 0
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
        .value(metric: .min)
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
        .value(metric: .max)
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
        .value(metric: .average)
    }
}
