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
///     .take(20)
/// ```
///
public struct QueryBuilder: Sendable {
    let entity: String
    let store: EntityStore

    private var filters: [EntityStore.Filter] = []
    private var groups: [[[EntityStore.Filter]]] = []
    private var sorts: [EntityStore.Sort] = []
    private var projection: [String]?
    private var ceiling: Int?
    private var creator: String?

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

    /// Excludes the records matching the filter — a `NOT` over one predicate.
    ///
    /// A comparison, equality or `in` over an always-present slot field —
    /// `.required`, or carrying a `.defaultValue` — is sent to the server as its
    /// complementary operator; every other negation is evaluated client-side
    /// after decoding, so a record missing the field is kept. `near` and
    /// `search` cannot be negated.
    ///
    public func exclude(_ filter: EntityStore.Filter) -> Self {
        var negated = filter
        negated.negated = true
        var builder = self
        builder.filters.append(negated)
        return builder
    }

    /// Excludes from the filter's parts: `.exclude("status", .equals, "archived")`.
    public func exclude(_ field: String, _ method: EntityStore.Match, _ value: RecordValue) -> Self {
        exclude(EntityStore.Filter(field: field, op: method, value: value))
    }

    /// Adds a group of alternatives combined with `OR`.
    ///
    /// The group as a whole is `AND`-ed with the other filters. An alternative
    /// added with `all` requires every one of its filters at once.
    ///
    /// ```swift
    /// .group {
    ///     $0.filter("level", .equals, "error")
    ///     $0.all("level" == "warning", "count" > 10)
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

    var spliceable: (filters: [EntityStore.Filter], sort: [EntityStore.Sort])? {
        guard groups.isEmpty, ceiling == nil, projection == nil, creator == nil else { return nil }
        return (filters, sorts)
    }

    /// Adds a sort clause; clauses apply in the order they are added.
    public func sort(_ field: String, _ direction: Direction = .ascending) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort(field: field, ascending: direction == .ascending))
        return builder
    }

    /// Sorts nearest-first by a location field's distance from the point.
    public func nearest(_ field: String, latitude: Double, longitude: Double) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort.distance(from: field, latitude: latitude, longitude: longitude))
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

    /// Keeps only the records a given user created — the public-database
    /// scoping, applied server-side through `creatorUserRecordID`.
    ///
    /// The scope is part of the query, so every terminal honors it: reads,
    /// pages, streams, folds, and the `update`/`delete` sweeps alike. A scoped
    /// fold or count always scans, since an aggregate view's grid folds every
    /// writer's records together.
    ///
    public func createdBy(_ user: String) -> Self {
        var builder = self
        builder.creator = user
        return builder
    }

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
    public func take(_ count: Int) async throws -> [EntityRecord] {
        try await records(limit: Swift.min(count, ceiling ?? count))
    }

    func records(limit: Int?) async throws -> [EntityRecord] {
        if groups.count > 0 {
            return try await store.read(entity: entity, any: branches(), sort: sorts, fields: projection, limit: limit, createdBy: creator)
        }
        return try await store.read(entity: entity, filters: filters, sort: sorts, fields: projection, limit: limit, createdBy: creator)
    }

    var bound: Int? { ceiling }

    /// Runs the query and returns the first matching record.
    public func first() async throws -> EntityRecord? {
        try await take(1).first
    }

    /// Runs the query and returns the number of matching records.
    ///
    /// A query a declared view covers — no creator scope, and filters limited
    /// to an equality, `in` list, or OR branches of them on the view's
    /// `groupBy`, an `envelopeDate` range aligned with the view's cell
    /// resolution (hours for an hour view, days for day and weekday views), or
    /// a threshold landing on a histogram bound — is answered from the view's
    /// grid without scanning records. A strict threshold over an integer field
    /// counts as the half-open one it equals, so `> 15` lands on a bound of 16.
    /// A threshold on an integer field a view groups by is answered without a
    /// histogram at all when the field's `minimum` and `maximum` bound it to a
    /// domain the range can name value by value.
    /// Every other query scans, fetching only the envelope and the filtered
    /// fields rather than full payloads.
    ///
    public func count() async throws -> Int {
        if creator == nil, let counted = try await store.viewCount(entity: entity, any: branches()) {
            return Swift.min(counted, ceiling ?? Int.max)
        } else if groups.count > 0 {
            return try await store.read(entity: entity, any: branches(), sort: sorts, fields: [], limit: ceiling, createdBy: creator).count
        } else {
            return try await store.read(entity: entity, filters: filters, sort: sorts, fields: [], limit: ceiling, createdBy: creator).count
        }
    }

    /// Sums a numeric field across the matching records, fetching only that field.
    public func sum(_ field: String) async throws -> Double {
        try await store.aggregate(.sum, of: field, entity: entity, any: branches(), createdBy: creator) ?? 0
    }

    /// The smallest value of a numeric field across the matching records, if any match.
    public func minimum(_ field: String) async throws -> Double? {
        try await store.aggregate(.minimum, of: field, entity: entity, any: branches(), createdBy: creator)
    }

    /// The largest value of a numeric field across the matching records, if any match.
    public func maximum(_ field: String) async throws -> Double? {
        try await store.aggregate(.maximum, of: field, entity: entity, any: branches(), createdBy: creator)
    }

    /// The mean of a numeric field across the matching records, if any match.
    public func average(_ field: String) async throws -> Double? {
        try await store.aggregate(.average, of: field, entity: entity, any: branches(), createdBy: creator)
    }

    /// Sums a numeric field per distinct value of the grouping field.
    public func sum(_ field: String, by group: String) async throws -> [String: Double] {
        try await store.aggregate(.sum, of: field, by: group, entity: entity, any: branches(), createdBy: creator)
    }

    /// The smallest value of a numeric field per distinct value of the grouping field.
    public func minimum(_ field: String, by group: String) async throws -> [String: Double] {
        try await store.aggregate(.minimum, of: field, by: group, entity: entity, any: branches(), createdBy: creator)
    }

    /// The largest value of a numeric field per distinct value of the grouping field.
    public func maximum(_ field: String, by group: String) async throws -> [String: Double] {
        try await store.aggregate(.maximum, of: field, by: group, entity: entity, any: branches(), createdBy: creator)
    }

    /// The mean of a numeric field per distinct value of the grouping field.
    public func average(_ field: String, by group: String) async throws -> [String: Double] {
        try await store.aggregate(.average, of: field, by: group, entity: entity, any: branches(), createdBy: creator)
    }

    /// Counts the matching records per distinct value of the grouping field.
    public func count(by group: String) async throws -> [String: Int] {
        try await store.counts(by: group, entity: entity, any: branches(), createdBy: creator)
    }

    /// Returns one page of results ordered by the envelope date.
    ///
    /// Keyset pagination is ordered by the envelope date alone, so combining it
    /// with ``sort(_:_:)`` throws instead of silently ignoring the clause.
    ///
    public func paginate(size: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        guard sorts.isEmpty else {
            throw SchemaError.invalidDefinition("Pagination is ordered by the envelope date and cannot honor sort clauses")
        }
        return try await store.read(entity: entity, any: branches(), fields: projection, limit: size, after: cursor, createdBy: creator)
    }

    /// Returns one keyset page ordered by the builder's sort clause.
    ///
    /// Requires exactly one `sort(_:_:)` clause on a slot-backed scalar field;
    /// OR groups are honored. Envelope-date pages stay with `paginate(size:after:)`.
    ///
    public func page(size: Int, after cursor: FieldCursor? = nil) async throws -> FieldPage {
        guard sorts.count == 1, let sort = sorts.first else {
            throw SchemaError.invalidDefinition("A field-ordered page requires exactly one sort clause")
        }
        return try await store.read(
            entity: entity, any: branches(), fields: projection, orderedBy: sort.field, descending: !sort.ascending, limit: size, after: cursor,
            createdBy: creator)
    }

    /// Streams every matching record page by page.
    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        store.stream(entity: entity, any: branches(), fields: projection, pageSize: pageSize, createdBy: creator)
    }

    @discardableResult public func update(_ transform: (inout EntityRecord) throws -> Void) async throws -> Int {
        try await store.updateAll(entity: entity, any: branches(), createdBy: creator, transform: transform)
    }

    @discardableResult public func delete() async throws -> Int {
        try await store.deleteAll(entity: entity, any: branches(), createdBy: creator)
    }

    /// Explains how the query splits into server predicates and client matchers,
    /// one `QueryPlan` per OR branch.
    ///
    /// A query with no `.group { … }` yields a single plan; each added group
    /// multiplies the branches, since the store runs one server query per branch
    /// of the disjunction. Earlier this dropped the groups and described only the
    /// base filters — a plan for a query that was never run.
    ///
    public func explain() async throws -> [QueryPlan] {
        try await store.explain(entity: entity, any: branches(), sort: sorts, createdBy: creator)
    }

    private func branches() -> [[EntityStore.Filter]] {
        groups.reduce([filters]) { branches, group in
            if let folded = Self.folded(group) {
                return branches.map { $0 + [folded] }
            }
            return branches.flatMap { branch in group.map { branch + $0 } }
        }
    }

    private static func folded(_ group: [[EntityStore.Filter]]) -> EntityStore.Filter? {
        let single = group.compactMap { $0.count == 1 ? $0[0] : nil }
        guard single.count == group.count, single.count > 1, let field = single.first?.field,
            single.allSatisfy({ $0.field == field && $0.op == .equals && !$0.negated && $0.radius == nil }),
            let list = EntityStore.membership(of: single.map(\.value))
        else { return nil }
        return EntityStore.Filter(field: field, op: .in, value: list)
    }
}

/// Collects the alternatives of a ``QueryBuilder/group(_:)`` clause.
public struct OrGroup {
    fileprivate var alternatives: [[EntityStore.Filter]] = []

    /// Adds one alternative to the group.
    public mutating func filter(_ filter: EntityStore.Filter) {
        alternatives.append([filter])
    }

    /// Adds one alternative from its parts.
    public mutating func filter(_ field: String, _ method: EntityStore.Match, _ value: RecordValue) {
        alternatives.append([EntityStore.Filter(field: field, op: method, value: value)])
    }

    /// Adds one alternative that requires all of its filters at once — an `AND`
    /// nested inside the group's `OR`.
    public mutating func all(_ filters: EntityStore.Filter...) {
        alternatives.append(filters)
    }
}

extension EntityStore {
    /// Opens a chained query on an entity.
    public func query(_ entity: String) -> QueryBuilder {
        QueryBuilder(entity: entity, store: self)
    }
}
