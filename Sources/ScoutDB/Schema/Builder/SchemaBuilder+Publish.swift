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
    /// slot — gets a `lifetime` view counting its values, and an entity with an
    /// envelope date also gets a `day` view counting its records. So `count`,
    /// `count(by:)` and `distinct` are answered from the grid without anyone
    /// declaring anything; ``sum(_:by:bucket:shards:)`` and its siblings remain
    /// for the shapes nobody can guess, like a metric, a histogram or a coarser
    /// bucket.
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
    ///     .envelopeDate("date")
    ///     .create()
    /// ```
    ///
    public func create() async throws {
        var allocator = SlotAllocator()

        let fields = try declarations.map {
            try resolve($0, allocator: &allocator, since: nil)
        }

        let grid = Self.grid(
            over: fields,
            declaring: views,
            envelopeDate: envelopeDate
        )

        try await publish(
            fields: fields,
            version: 1,
            inheriting: nil,
            publishing: grid
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
    /// version and backfill with `Migrator.backfill(view:entity:)`, mark them
    /// `.ungrouped` to say they are meant to go uncounted, or leave them to be
    /// answered by reading records.
    ///
    /// ```swift
    /// let uncounted = try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("status", .string)
    ///     .field("date", .timestamp)
    ///     .envelopeDate("date")
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

            if let active, active.type == declaration.type, active.storage.isSlot == declaration.wantsSlot {
                var kept = try resolve(
                    declaration,
                    allocator: &allocator,
                    since: active.since,
                    storage: active.storage
                )

                kept.until = active.until
                fields.append(kept)
                carried.insert(declaration.name)
            } else {
                fields.append(
                    try resolve(
                        declaration,
                        allocator: &allocator,
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

        let carriedViews = Self.merge(
            views,
            onto: previous.views ?? [],
            keeping: active
        )

        try await publish(
            fields: fields,
            version: version,
            inheriting: previous,
            publishing: carriedViews
        )

        let counted = Set(carriedViews.compactMap(\.groupBy))

        return fields.filter {
            $0.since == version && Self.groupable($0) && !counted.contains($0.name)
        }
        .map(\.name)
    }

    func publish(fields: [FieldDefinition], version: Int, inheriting previous: EntityDefinition?, publishing views: [AggregateView]) async throws {
        let envelope = envelopeDate ?? previous?.envelopeDate
        let definition = EntityDefinition(
            entity: entity,
            version: version,
            fields: fields,
            envelopeDate: envelope,
            unique: unique ?? previous?.unique,
            uniqueKeys: uniqueKeys ?? previous.flatMap { $0.claimedKeys.isEmpty ? nil : $0.claimedKeys },
            views: views.isEmpty ? nil : views,
            keyID: keyID ?? previous?.keyID
        )
        try await registry.publish(definition)
    }
}
