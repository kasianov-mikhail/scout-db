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
    let slots = GridCache()

    var aggregator: GridAggregator {
        GridAggregator(database: database, slots: slots)
    }

    /// Creates a store backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase, registry: SchemaRegistry) {
        self.database = database
        self.registry = registry
    }

    struct Filter: Equatable, Sendable {
        let field: String
        let op: Operator
        let value: RecordValue
    }

    struct Sort: Equatable, Sendable {
        let field: String
        var ascending = true

        init(field: String, ascending: Bool = true) {
            self.field = field
            self.ascending = ascending
        }
    }
}
