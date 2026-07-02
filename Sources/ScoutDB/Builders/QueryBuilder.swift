//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A chainable query builder over an entity.
///
/// ```swift
/// let recent = try await store.query("purchase")
///     .filter("quantity" > 2)
///     .filter("product_id", .equals, "sku-42")
///     .sort("date", .descending)
///     .limit(20)
///     .all()
/// ```
///
public struct QueryBuilder {
    let entity: String
    let store: EntityStore

    private var filters: [EntityStore.Filter] = []
    private var groups: [[EntityStore.Filter]] = []
    private var sorts: [EntityStore.Sort] = []
    private var projection: [String]?
    private var ceiling: Int?

    init(entity: String, store: EntityStore) {
        self.entity = entity
        self.store = store
    }

    /// The direction of a ``sort(_:_:)`` clause.
    public enum Direction: Sendable {
        case ascending
        case descending
    }

    /// Adds a filter built with the operator sugar: `.filter("quantity" > 5)`.
    public func filter(_ filter: EntityStore.Filter) -> Self {
        var builder = self
        builder.filters.append(filter)
        return builder
    }

    /// Adds a filter from its parts: `.filter("product_id", .equals, "sku-42")`.
    public func filter(_ field: String, _ method: EntityStore.Match, _ value: RecordValue, radius: Double? = nil) -> Self {
        filter(EntityStore.Filter(field: field, op: method, value: value, radius: radius))
    }

    /// Adds a group of alternatives combined with `OR`; the group as a whole is
    /// `AND`-ed with the other filters.
    ///
    /// ```swift
    /// .group {
    ///     $0.filter("level", .equals, "error")
    ///     $0.filter("level", .equals, "fatal")
    /// }
    /// ```
    ///
    public func group(_ build: (inout OrGroup) -> Void) -> Self {
        var group = OrGroup()
        build(&group)
        var builder = self
        builder.groups.append(group.alternatives)
        return builder
    }

    /// Adds a sort clause; clauses apply in the order they are added.
    public func sort(_ field: String, _ direction: Direction = .ascending) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort(field: field, ascending: direction == .ascending))
        return builder
    }

    /// Fetches only the named fields; filtered fields are included automatically.
    public func fields(_ fields: String...) -> Self {
        var builder = self
        builder.projection = fields
        return builder
    }

    /// Caps the number of returned records.
    public func limit(_ count: Int) -> Self {
        var builder = self
        builder.ceiling = count
        return builder
    }

    /// Runs the query and returns every matching record.
    public func all() async throws -> [EntityRecord] {
        var records: [EntityRecord]
        if groups.count > 0 {
            records = try await store.read(entity: entity, any: branches(), sort: sorts)
        } else {
            records = try await store.read(entity: entity, filters: filters, sort: sorts, fields: projection)
        }
        if let ceiling {
            records = Array(records.prefix(ceiling))
        }
        return records
    }

    /// Runs the query and returns the first matching record.
    public func first() async throws -> EntityRecord? {
        try await limit(1).all().first
    }

    /// Runs the query and returns the number of matching records.
    public func count() async throws -> Int {
        try await all().count
    }

    /// Returns one page of results ordered by the envelope date.
    public func paginate(size: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        try await store.read(entity: entity, filters: filters, limit: size, after: cursor)
    }

    /// Streams every matching record page by page.
    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        store.stream(entity: entity, filters: filters, pageSize: pageSize)
    }

    /// Rewrites every matching record through the transform.
    @discardableResult public func update(_ transform: (inout EntityRecord) throws -> Void) async throws -> Int {
        try await store.updateAll(entity: entity, filters: filters, transform: transform)
    }

    /// Tombstones every matching record.
    @discardableResult public func delete() async throws -> Int {
        try await store.deleteAll(entity: entity, filters: filters)
    }

    /// Explains how the query splits into server predicates and client matchers.
    public func explain() async throws -> QueryPlan {
        try await store.explain(entity: entity, filters: filters, sort: sorts)
    }

    // Distributes the AND-ed base filters over the OR groups into disjunctive
    // normal form: one branch per combination of picks, one query per branch.
    private func branches() -> [[EntityStore.Filter]] {
        groups.reduce([filters]) { branches, group in
            branches.flatMap { branch in group.map { branch + [$0] } }
        }
    }
}

/// Collects the alternatives of a ``QueryBuilder/group(_:)`` clause.
public struct OrGroup {
    fileprivate var alternatives: [EntityStore.Filter] = []

    /// Adds one alternative to the group.
    public mutating func filter(_ filter: EntityStore.Filter) {
        alternatives.append(filter)
    }

    /// Adds one alternative from its parts.
    public mutating func filter(_ field: String, _ method: EntityStore.Match, _ value: RecordValue) {
        alternatives.append(EntityStore.Filter(field: field, op: method, value: value))
    }
}

extension EntityStore {
    /// Opens a Fluent-style query on an entity.
    public func query(_ entity: String) -> QueryBuilder {
        QueryBuilder(entity: entity, store: self)
    }
}
