//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Runs the query and returns at most `count` matching records.
    ///
    /// The bound is what makes this the read every entity can afford: it holds
    /// server-side, so the store stops following the query cursor as soon as
    /// enough records are in hand, and the call costs what it returns however
    /// much the entity grows. A ``limit(_:)`` already on the builder still
    /// stands — the smaller of the two wins. To read past the bound, walk the
    /// query with ``paginate(size:after:)``, ``page(size:after:)`` or
    /// ``stream(pageSize:)``, which hand back a cursor instead of a tail the
    /// caller cannot see.
    ///
    /// ```swift
    /// let recent = try await store.query("purchase")
    ///     .sort("date", .descending)
    ///     .take(20)
    /// ```
    ///
    public func take(_ count: Int) async throws -> [EntityRecord] {
        try await records(limit: Swift.min(count, ceiling ?? count))
    }

    func records(limit: Int?) async throws -> [EntityRecord] {
        try await store.read(
            entity: entity,
            any: alternatives,
            sort: sorts,
            fields: projection,
            limit: limit,
            createdBy: creator
        )
    }

    /// Runs the query and returns the first matching record, if any.
    ///
    /// A ``take(_:)`` of one under a different name, so the sort clause decides
    /// which record "first" means and the server stops after it.
    ///
    /// ```swift
    /// let newest = try await store.query("purchase")
    ///     .filter("product_id" == "sku-42")
    ///     .sort("date", .descending)
    ///     .first()
    /// ```
    ///
    public func first() async throws -> EntityRecord? {
        try await records(limit: Swift.min(1, ceiling ?? 1)).first
    }

    /// Returns one page of results ordered by the envelope date.
    ///
    /// Keyset pagination is ordered by the envelope date alone, so combining it
    /// with ``sort(_:_:)`` throws instead of silently ignoring the clause.
    ///
    /// ```swift
    /// var cursor: EntityCursor?
    /// repeat {
    ///     let page = try await store.query("purchase").paginate(size: 100, after: cursor)
    ///     render(page.records)
    ///     cursor = page.cursor
    /// } while cursor != nil
    /// ```
    ///
    public func paginate(size: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        guard sorts.isEmpty else {
            throw SchemaError.invalidDefinition("Pagination is ordered by the envelope date and cannot honor sort clauses")
        }
        return try await store.read(
            entity: entity,
            any: alternatives,
            fields: projection,
            limit: size,
            after: cursor,
            createdBy: creator
        )
    }

    /// Returns one keyset page ordered by the builder's sort clause.
    ///
    /// Requires exactly one `sort(_:_:)` clause on a slot-backed scalar field;
    /// disjunctions are honored. Envelope-date pages stay with
    /// `paginate(size:after:)`.
    ///
    /// ```swift
    /// let first = try await store.query("purchase").sort("amount").page(size: 50)
    /// let next = try await store.query("purchase").sort("amount").page(size: 50, after: first.cursor)
    /// ```
    ///
    public func page(size: Int, after cursor: FieldCursor? = nil) async throws -> FieldPage {
        guard sorts.count == 1, let sort = sorts.first else {
            throw SchemaError.invalidDefinition("A field-ordered page requires exactly one sort clause")
        }
        return try await store.read(
            entity: entity,
            any: alternatives,
            fields: projection,
            orderedBy: sort.field,
            descending: !sort.ascending,
            limit: size,
            after: cursor,
            createdBy: creator
        )
    }

    /// Streams every matching record, a page at a time.
    ///
    /// The stream follows the query's cursor, so it holds one page rather than
    /// the whole result and walks an entity of any size. Ordered by the envelope
    /// date, like ``paginate(size:after:)``.
    ///
    /// ```swift
    /// for try await purchase in store.query("purchase").stream(pageSize: 200) {
    ///     try await archive(purchase)
    /// }
    /// ```
    ///
    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        store.stream(
            entity: entity,
            any: alternatives,
            fields: projection,
            pageSize: pageSize,
            createdBy: creator
        )
    }

    /// Explains how the query splits into server predicates and client matchers,
    /// one `QueryPlan` per alternative.
    ///
    /// A query with no `||` yields a single plan; every alternative the
    /// expression carries adds one, since the store runs a server query per
    /// alternative. Reading the plans is how you see what a disjunction came to
    /// cost before running it.
    ///
    /// ```swift
    /// for plan in try await store.query("purchase").filter("title", .endsWith, "World").explain() {
    ///     print(plan)   // SERVER title_rev BEGINSWITH "dlroW" …
    /// }
    /// ```
    ///
    public func explain() async throws -> [QueryPlan] {
        try await store.explain(
            entity: entity,
            any: alternatives,
            sort: sorts,
            createdBy: creator
        )
    }
}
