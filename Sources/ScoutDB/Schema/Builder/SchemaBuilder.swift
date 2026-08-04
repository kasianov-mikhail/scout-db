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
    var aggregates: [AggregateDefinition] = []
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
