//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct EntityStore: Sendable {
    let database: any CloudDatabase
    let registry: SchemaRegistry
    let slots = VectorCache()

    /// Creates a store backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase, registry: SchemaRegistry) {
        self.database = database
        self.registry = registry
    }

    struct Sort: Equatable, Sendable {
        let field: String
        var order: SortOrder = .forward
    }
}
