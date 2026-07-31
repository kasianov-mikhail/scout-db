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
    /// A query a declared aggregate covers — no creator scope, and filters
    /// limited to an equality, `in` list, or alternatives of them on the
    /// aggregate's grouping — is answered from the grid without scanning
    /// records. A threshold on an integer field an aggregate groups by is
    /// answered from the grid too when the field's `min` and `max` bound it to
    /// a domain the range can name value by value; a strict threshold counts as
    /// the half-open one it equals, so `> 15` reads as `>= 16`. Every other
    /// query scans, fetching only the envelope and the filtered fields rather
    /// than full payloads.
    ///
    /// ```swift
    /// let paid = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .count()
    /// ```
    ///
    public func count() async throws -> Int {
        if creator == nil, let counted = try await store.count(entity: entity, any: alternatives) {
            return Swift.min(counted, ceiling ?? Int.max)
        }
        return try await store.read(
            entity: entity,
            any: alternatives,
            sort: sorts,
            fields: [],
            limit: ceiling,
            createdBy: creator
        )
        .count
    }

    /// Sums a numeric field across the matching records.
    ///
    /// The fold is answered from an aggregate's grid when one covers the query
    /// and reads records otherwise, fetching that field alone. Records missing
    /// the field contribute nothing; with no match at all the sum is zero.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .sum("amount")
    /// ```
    ///
    public func sum(_ field: String) async throws -> Double {
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .value(fold: .sum, field: field) ?? 0
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .value(fold: .min, field: field)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .value(fold: .max, field: field)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .value(fold: .average, field: field)
    }

    /// Sums a numeric field per distinct value of the grouping field.
    ///
    /// One entry per value the grouping field takes among the matching records.
    /// An aggregate grouped by that field answers it without reading records;
    /// otherwise the query scans, fetching the two fields it folds.
    ///
    /// ```swift
    /// let byProduct = try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .sum("amount", by: "product_id")
    /// // ["sku-42": 1250.0, "sku-7": 310.0]
    /// ```
    ///
    public func sum(_ field: String, by group: String) async throws -> [String: Double] {
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .values(fold: .sum, field: field, group: group)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .values(fold: .min, field: field, group: group)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .values(fold: .max, field: field, group: group)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .values(fold: .average, field: field, group: group)
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
        try await FoldQuery(
            store: store,
            entity: entity,
            branches: alternatives,
            creator: creator
        )
        .counts(group: group)
    }

    /// The distinct values a field takes across the matching records.
    ///
    /// A grid counting by the field answers the query shapes ``count()``
    /// covers — one row per live value, without reading records — as long as
    /// the field is required or defaulted. Every other shape scans, fetching
    /// only that field.
    ///
    /// ```swift
    /// let products = try await store.query("purchase").distinct("product_id")
    /// ```
    ///
    public func distinct(_ field: String) async throws -> [RecordValue] {
        guard let branch = flat else {
            throw SchemaError.invalidDefinition("Distinct values are read off the grid and cannot honor a disjunction")
        }
        return try await store.distinct(
            entity: entity,
            field: field,
            filters: branch
        )
    }

    /// One total per group, folded across every record the grid counts.
    ///
    /// One row per group: the count, the metric's value, and the `average`,
    /// `variance` and `standardDeviation` derived from them. Without a `field`
    /// the rows count alone. The only clause a grid read can honor is an
    /// equality filter on the grouping field, which narrows it to that group
    /// server-side; any other filter throws rather than being quietly dropped.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .totals("amount", by: "product_id")
    /// // [AggregateTotal(group: "sku-42", count: 48211, value: 481628.9), ...]
    /// ```
    ///
    public func totals(_ field: String? = nil, by group: String? = nil) async throws -> [AggregateTotal] {
        try await GridQuery(self, field: field, group: group).totals()
    }
}

extension GridQuery {
    fileprivate init(_ query: QueryBuilder, field: String?, group: String?) async throws {
        let store = query.store
        let definition = try await store.registry.definition(for: query.entity)

        guard let view = definition.view(grouping: group, folding: field) else {
            let shape = [
                group.map { "grouped by '\($0)'" },
                field.map { "folding '\($0)'" },
            ]
            throw SchemaError.invalidDefinition(
                "Entity '\(query.entity)' keeps no aggregate \(shape.compactMap { $0 }.joined(separator: ", "))"
            )
        }

        self.init(
            store,
            entity: query.entity,
            view: view.name,
            group: try query.narrowing(to: group)
        )
    }
}

extension QueryBuilder {
    fileprivate func narrowing(to group: String?) throws -> String? {
        guard let flat else {
            throw SchemaError.invalidDefinition("An aggregate reads the grid and cannot honor a disjunction")
        }

        var narrowed: String?
        for filter in flat {
            guard let group, filter.field == group, filter.op == .equals else {
                throw SchemaError.invalidDefinition("An aggregate reads the grid and can only be filtered by an equal '\(group ?? "group")'")
            }
            narrowed = filter.value.canonical
        }
        return narrowed
    }
}
