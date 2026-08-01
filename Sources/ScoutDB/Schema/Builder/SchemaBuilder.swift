//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A chainable schema builder that assigns slots and versions automatically.
///
/// ```swift
/// try await store.schema("purchase")
///     .field("product_id", .string, .required)
///     .field("amount", .double)
///     .field("date", .timestamp)
///     .field("comment", .string, .payload)
///     .unique(on: "product_id", "date")
///     .create()
/// ```
///
/// `update()` publishes the next version: unchanged fields keep their slots,
/// retyped fields move to a fresh slot, and omitted fields are closed — old
/// records remain readable through their own version forever.
///
public struct SchemaBuilder {
    let entity: String
    let registry: SchemaRegistry

    var declarations: [Declaration] = []
    var unique: [String]?
    var views: [AggregateView] = []

    /// Derives the record id from the named fields, turning writes into
    /// upserts.
    ///
    /// The id is a digest of those values, so writing the same combination
    /// twice rewrites one record rather than making a second — and a write
    /// missing any of the fields is rejected. The uuid a caller passes is
    /// ignored, since identity comes from the values.
    ///
    /// ```swift
    /// try await store.schema("reading")
    ///     .field("sensor", .string, .required)
    ///     .field("taken", .timestamp, .required)
    ///     .unique(on: "sensor", "taken")
    ///     .create()
    /// ```
    ///
    public func unique(on fields: String...) -> Self {
        var builder = self
        builder.unique = fields
        return builder
    }
}

extension EntityStore {
    /// Opens a chained schema declaration for an entity.
    ///
    /// Nothing reaches the database until ``SchemaBuilder/create()`` or
    /// ``SchemaBuilder/update()`` publishes it, so the builder is a value to
    /// hold and pass around. Slots and versions are assigned for you — the
    /// declaration names fields and rules, never storage.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("date", .timestamp)
    ///     .create()
    /// ```
    ///
    public func schema(_ entity: String) -> SchemaBuilder {
        SchemaBuilder(entity: entity, registry: registry)
    }
}
