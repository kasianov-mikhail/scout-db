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
    /// A fold reads a vector or it throws — it never falls back to reading the
    /// records, because the cost of that fallback grows with the entity while
    /// the call site that asked for a count stays the same. The count comes off
    /// a counting aggregate, one that folds no metric: a cell holds one number,
    /// so the `sum` of a field is kept apart from the count of the records it
    /// came from. A query a declared aggregate covers — filters limited to an
    /// equality, `in` list, or alternatives of them on the aggregate's
    /// grouping — is answered from a vector. A threshold on an integer field an
    /// aggregate groups by is answered from a vector too when the field's `min`
    /// and `max` bound it to a domain the range can name value by value; a
    /// strict threshold counts as the half-open one it equals, so `> 15` reads
    /// as `>= 16`. Every other query throws
    /// ``QueryFault/noAggregate(entity:grouping:folding:)``, and the answer is
    /// to declare the aggregate it names — or to ``take(_:)`` the records and
    /// count them yourself, knowing what that reads.
    ///
    /// ```swift
    /// let paid = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .count()
    /// ```
    ///
    public func count() async throws -> Int {
        guard let fold = try await fold else {
            throw uncovered(nil)
        }
        let folded = try await fold.cell(of: nil, folding: .sum) ?? 0
        let counted = Int(exactly: folded.rounded()) ?? Int.max

        return Swift.min(counted, ceiling ?? Int.max)
    }

    /// Sums a numeric field across the matching records.
    ///
    /// Answered from the vector of an aggregate declaring `sum` of the field, and
    /// throws when none covers the query — as in ``count()``, there is no scan
    /// behind it. Records missing the field contribute nothing; with no match
    /// at all the sum is zero.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .sum("amount")
    /// ```
    ///
    public func sum(_ field: String) async throws -> Double {
        try await value(of: field, metric: .sum) ?? 0
    }

    /// The smallest value of a numeric field across the matching records.
    ///
    /// Answered from the vector of an aggregate declaring `min` of the field, and
    /// throws when none covers the query. `nil` when nothing matches or no
    /// match carries the field. The vector keeps a running extremum, so removing
    /// the record that set it leaves the value standing.
    ///
    /// ```swift
    /// let cheapest = try await store.query("purchase")
    ///     .filter("product_id" == "sku-42")
    ///     .min("amount")
    /// ```
    ///
    public func min(_ field: String) async throws -> Double? {
        try await value(of: field, metric: .min)
    }

    /// The largest value of a numeric field across the matching records.
    ///
    /// Answered from the vector of an aggregate declaring `max` of the field, and
    /// throws when none covers the query, standing after a removal as in
    /// ``min(_:)``.
    ///
    /// ```swift
    /// let biggest = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .max("amount")
    /// ```
    ///
    public func max(_ field: String) async throws -> Double? {
        try await value(of: field, metric: .max)
    }

    /// The mean of a numeric field across the matching records.
    ///
    /// A vector divides the running total by the count kept beside it, so this
    /// reads two aggregates covering the query — one declaring `sum` of the
    /// field, one counting — and throws when either is missing. The field must
    /// be `required` or carry a default, since the count divides in every
    /// record of the group — one missing the field would pull the mean down
    /// rather than stay out of it.
    ///
    /// ```swift
    /// let basket = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .average("amount")
    /// ```
    ///
    public func average(_ field: String) async throws -> Double? {
        try await value(of: field, metric: .average)
    }
}

extension QueryBuilder {
    private func value(of field: String, metric: Metric) async throws -> Double? {
        let definition = try await self.definition
        let target = try definition.field(field, at: definition.version)

        guard [.int, .double].contains(target.type) else {
            throw SchemaError.unsupportedQuery(.nonNumericField(field))
        }
        if metric == .average {
            try definition.requireAverageable(field)
        }
        guard let fold = try await fold else {
            throw uncovered(field)
        }
        guard metric == .average else {
            return try await fold.cell(of: field, folding: metric)
        }

        async let summed = fold.cell(of: field, folding: .sum)
        async let counted = fold.cell(of: nil, folding: .sum)

        guard let total = try await summed else {
            return nil
        }
        guard let count = try await counted, count != 0 else {
            return nil
        }

        return total / count
    }

    private func uncovered(_ field: String?) -> SchemaError {
        SchemaError.unsupportedQuery(
            .noAggregate(
                entity: entity,
                grouping: FilterPlan(branches: alternatives)?.groupField,
                folding: field
            )
        )
    }
}
