//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Orders the results by a field.
    ///
    /// Clauses apply in the order they are added, so the second breaks the ties
    /// of the first. Sorting is server-side over a slot-backed field; a payload
    /// field cannot be ordered on. A single clause over a scalar field is also
    /// what ``page(size:after:)`` pages by.
    ///
    /// ```swift
    /// try await store.query("purchase")
    ///     .sort("date", .descending)
    ///     .sort("quantity")
    ///     .take(20)
    /// ```
    ///
    public func sort(_ field: String, _ direction: Direction = .ascending) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort(field: field, ascending: direction == .ascending))
        return builder
    }

    /// Orders the results by how far a location field lies from the point,
    /// nearest first.
    ///
    /// The distance is computed for the ordering alone — pair it with
    /// ``filter(_:near:within:)`` to bound how far the query reaches.
    ///
    /// ```swift
    /// try await store.query("place")
    ///     .filter("location", near: GeoPoint(latitude: 52.5, longitude: 13.4), within: 2_000)
    ///     .nearest("location", latitude: 52.5, longitude: 13.4)
    ///     .take(10)
    /// ```
    ///
    public func nearest(_ field: String, latitude: Double, longitude: Double) -> Self {
        var builder = self
        builder.sorts.append(EntityStore.Sort.distance(from: field, latitude: latitude, longitude: longitude))
        return builder
    }

    /// Fetches only the named fields instead of whole records.
    ///
    /// The fields a filter or a sort needs are added for you, so a projection
    /// never breaks the query it narrows. What comes back is an `EntityRecord`
    /// carrying the named values and nothing else — cheaper over the wire, and
    /// the way to read a list without pulling every payload. A payload field
    /// brings the whole payload blob with it, so the saving is in the slots.
    ///
    /// ```swift
    /// try await store.query("purchase")
    ///     .fields("product_id", "amount")
    ///     .take(100)
    /// ```
    ///
    public func fields(_ fields: String...) -> Self {
        var builder = self
        builder.projection = fields
        return builder
    }

    /// Caps how many records the query may return.
    ///
    /// The cap rides on the builder, so every terminal honors it — a ``take(_:)``
    /// asking for more gets the smaller of the two, and ``count()`` stops at it
    /// as well.
    ///
    /// ```swift
    /// let newest = try await store.query("purchase")
    ///     .sort("date", .descending)
    ///     .limit(10)
    ///     .take(50)   // ten come back
    /// ```
    ///
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
    /// fold or count always scans, since an aggregate's grid folds every
    /// writer's records together.
    ///
    /// ```swift
    /// try await store.query("post")
    ///     .createdBy(userRecordName)
    ///     .sort("date", .descending)
    ///     .take(20)
    /// ```
    ///
    public func createdBy(_ user: String) -> Self {
        var builder = self
        builder.creator = user
        return builder
    }
}
