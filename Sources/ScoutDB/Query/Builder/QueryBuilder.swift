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
///     .filter("product_id" == "sku-42")
///     .sort("date", .reverse)
///     .take(20)
/// ```
///
public struct QueryBuilder: Sendable {
    let entity: String
    let store: EntityStore

    var alternatives: [[ClientFilter]] = [[]]
    var sorts: [EntityStore.Sort] = []
    var ceiling: Int?

    var flat: [ClientFilter]? {
        alternatives.count == 1 ? alternatives[0] : nil
    }

    var definition: EntityDefinition {
        get async throws {
            try await store.registry.definition(for: entity)
        }
    }
}

extension EntityStore {
    /// Opens a chained query on an entity.
    ///
    /// Nothing runs until a terminal asks for something — ``QueryBuilder/take(_:)``,
    /// ``QueryBuilder/count()``, a fold, a page or a sweep — so the builder is a
    /// value to hold, pass around and reuse.
    ///
    /// ```swift
    /// let recent = try await store.query("purchase")
    ///     .filter("quantity" > 2)
    ///     .sort("date", .reverse)
    ///     .take(20)
    /// ```
    ///
    public func query(_ entity: String) -> QueryBuilder {
        QueryBuilder(entity: entity, store: self)
    }
}
