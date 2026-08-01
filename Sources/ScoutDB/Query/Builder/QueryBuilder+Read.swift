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
    /// query with ``page(size:after:)``, which hands back a cursor instead of a
    /// tail the caller cannot see.
    ///
    /// ```swift
    /// let recent = try await store.query("purchase")
    ///     .sort("date", .descending)
    ///     .take(20)
    /// ```
    ///
    public func take(_ count: Int) async throws -> [EntityRecord] {
        try await EntityReader(store: store, entity: entity, sort: sorts, limit: Swift.min(count, ceiling ?? count))
            .read(any: alternatives)
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
        try await take(1).first
    }

    /// Returns one keyset page ordered by the builder's sort clause.
    ///
    /// Requires exactly one `sort(_:_:)` clause on a slot-backed scalar field;
    /// disjunctions are honored.
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
            orderedBy: sort.field,
            descending: !sort.ascending,
            limit: size,
            after: cursor
        )
    }
}
