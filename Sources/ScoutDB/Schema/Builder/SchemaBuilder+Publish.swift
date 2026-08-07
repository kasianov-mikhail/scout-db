//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    /// Publishes version 1 of the entity, over the vectors it builds itself.
    ///
    /// Every groupable field — a scalar string, reference, int or double in a
    /// slot — gets an aggregate counting its values. So `count` and `totals(metric:group:)`
    /// are answered from a vector without anyone declaring anything;
    /// ``sum(_:by:at:shards:)`` and its siblings remain for the shapes nobody can
    /// guess, like a metric over a field — and they join the count rather than
    /// standing in for it, since a cell holds one number.
    ///
    /// A vector covers one group over one week, holding a cell per hour of it.
    /// Nothing filters them server-side: a vector is reached by the digest of
    /// its key, and an index record per aggregate — with one per week under it
    /// — names the weeks and groups that exist, so a fold over every group
    /// knows what to reach for.
    ///
    /// The vectors cost the writes they save the reads: an entity carrying them
    /// reads its records before it rewrites them and rewrites its cells after,
    /// and a group or week seen for the first time costs a read and a write of
    /// the index besides. `update()` inherits whatever this published — it
    /// never builds vectors of its own, so a field added later needs its
    /// aggregate declared.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("amount", .double)
    ///     .field("date", .timestamp)
    ///     .create()
    /// ```
    ///
    public func create() async throws {
        var allocator = SlotAllocator()

        let fields = try declarations.map {
            try allocator.resolve($0, since: nil)
        }

        var taken = Set(aggregates.map(\.name))
        var vectors = aggregates

        for field in fields {
            guard isSlot(field.storage), field.isGroupable else {
                continue
            }
            guard taken.insert("by_\(field.name)").inserted else {
                continue
            }
            vectors.append(AggregateDefinition(group: field.name))
        }

        try await registry.publish(
            EntityDefinition(
                entity: entity,
                version: 1,
                fields: fields,
                aggregates: vectors
            )
        )
    }

    /// Publishes the next version, diffed against the current one, and names
    /// the fields it added that nothing counts by.
    ///
    /// A field keeps its slot while its name and type hold; retyping moves it
    /// to a fresh slot and closes the old one at this version; omitting it
    /// closes it outright. Records written under earlier versions stay readable
    /// through their own, so nothing is rewritten here. Aggregates join rather
    /// than replace — one lapses only with the field it is kept over.
    ///
    /// A version builds no vector of its own: the entity already holds records,
    /// and a fresh cell counts only what lands after it. The returned names are
    /// that missing coverage — declare `count(by:)` for them on a further
    /// version to have it kept from there on, mark them `.ungrouped` to say they
    /// are meant to go uncounted, or leave them to be answered by reading
    /// records.
    ///
    /// ```swift
    /// let uncounted = try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("status", .string)
    ///     .field("date", .timestamp)
    ///     .update()
    /// // ["status"]
    /// ```
    ///
    @discardableResult public func update() async throws -> [String] {
        let previous = try await registry.definition(for: entity)
        let version = previous.version + 1

        var allocator = SlotAllocator(reserving: previous.fields)
        var fields: [FieldDefinition] = []
        var carried: Set<String> = []

        for declaration in declarations {
            let active = previous.activeFields.first { $0.name == declaration.name }

            if let active, active.type == declaration.type, isSlot(active.storage) == declaration.wantsSlot {
                var kept = try allocator.resolve(
                    declaration,
                    since: active.since,
                    storage: active.storage
                )

                kept.until = active.until
                fields.append(kept)
                carried.insert(declaration.name)
            } else {
                fields.append(
                    try allocator.resolve(
                        declaration,
                        since: version
                    )
                )
            }
        }

        for field in previous.fields {
            let redeclared = carried.contains(field.name) && field.isActive(at: previous.version)
            if redeclared {
                continue
            }

            var closed = field
            if field.isActive(at: previous.version), field.until == nil {
                closed.until = version
            }
            fields.append(closed)
        }

        let active = Set(fields.filter { $0.isActive(at: version) }.map(\.name))

        let inherited = previous.aggregates
        let byName = Dictionary(aggregates.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })

        var merged = inherited.map { aggregate in
            byName[aggregate.name] ?? aggregate
        }
        merged += aggregates.filter { aggregate in !inherited.contains { $0.name == aggregate.name } }

        let carriedViews = merged.filter { aggregate in
            [aggregate.groupBy, aggregate.measure?.field, aggregate.measure?.histogram?.field]
                .compactMap(\.self)
                .allSatisfy(active.contains)
        }

        try await registry.publish(
            EntityDefinition(
                entity: entity,
                version: version,
                fields: fields,
                aggregates: carriedViews
            )
        )

        let counted = Set(carriedViews.compactMap(\.groupBy))

        return fields.filter { field in
            guard field.since == version, isSlot(field.storage) else {
                return false
            }
            return field.isGroupable && !counted.contains(field.name)
        }
        .map(\.name)
    }
}

private func isSlot(_ storage: Storage) -> Bool {
    if case .slot = storage { true } else { false }
}
