//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    /// Publishes version 1 of the entity, over a grid it builds itself.
    ///
    /// Every groupable field — a scalar string, reference, int or double in a
    /// slot — gets an aggregate counting its values. So `count` and `totals(metric:group:)`
    /// are answered from the grid without anyone declaring anything;
    /// ``sum(_:by:shards:)`` and its siblings remain for the shapes nobody can
    /// guess, like a metric over a field.
    ///
    /// The grid costs the writes it saves the reads: an entity carrying one
    /// reads its records before it rewrites them and rewrites its cells after,
    /// three requests per write batch on top of the save. `update()` inherits
    /// whatever this published — it never builds a grid of its own, so a field
    /// added later needs its aggregate declared.
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
        var counted = Set(aggregates.compactMap(\.groupBy))
        var grid = aggregates

        for field in fields {
            guard isSlot(field.storage), field.ungrouped != true,
                [.string, .reference, .int, .double].contains(field.type),
                taken.insert("by_\(field.name)").inserted,
                counted.insert(field.name).inserted
            else {
                continue
            }
            grid.append(AggregateDefinition(by: field.name))
        }

        try await registry.publish(
            EntityDefinition(
                entity: entity,
                version: 1,
                fields: fields,
                unique: unique,
                aggregates: grid.isEmpty ? nil : grid
            )
        )
    }

    /// Publishes the next version, diffed against the current one, and names
    /// the fields it added that nothing counts by.
    ///
    /// A field keeps its slot while its name and type hold; retyping moves it
    /// to a fresh slot and closes the old one at this version; omitting it
    /// closes it outright. Records written under earlier versions stay readable
    /// through their own, so nothing is rewritten here. Settings carry over
    /// unless redeclared, and aggregates join rather than replace — one lapses
    /// only with the field it is kept over.
    ///
    /// A version builds no grid of its own: the entity already holds records,
    /// and a fresh cell counts only what lands after it. The returned names are
    /// that missing coverage — declare `count(by:)` for them on a further
    /// version and backfill with `Migrator.backfill(aggregate:entity:)`, mark them
    /// `.ungrouped` to say they are meant to go uncounted, or leave them to be
    /// answered by reading records.
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
            let active =
                previous
                .fields(at: previous.version)
                .first { $0.name == declaration.name }

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

        let inherited = previous.aggregates ?? []
        let byName = Dictionary(aggregates.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        let superseded = aggregates.map(\.groupBy)

        var merged = inherited.compactMap { aggregate -> AggregateDefinition? in
            if let replacement = byName[aggregate.name] {
                return replacement
            }
            return aggregate.metricField == nil && superseded.contains(aggregate.groupBy) ? nil : aggregate
        }
        merged += aggregates.filter { aggregate in !inherited.contains { $0.name == aggregate.name } }

        let carriedViews = merged.filter { aggregate in
            [aggregate.groupBy, aggregate.metricField]
                .compactMap(\.self)
                .allSatisfy(active.contains)
        }

        try await registry.publish(
            EntityDefinition(
                entity: entity,
                version: version,
                fields: fields,
                unique: unique ?? previous.unique,
                aggregates: carriedViews.isEmpty ? nil : carriedViews
            )
        )

        let counted = Set(carriedViews.compactMap(\.groupBy))

        return fields.filter { field in
            guard field.since == version, isSlot(field.storage), field.ungrouped != true else {
                return false
            }
            return [.string, .reference, .int, .double].contains(field.type)
                && !counted.contains(field.name)
        }
        .map(\.name)
    }
}

private func isSlot(_ storage: Storage) -> Bool {
    if case .slot = storage { true } else { false }
}
