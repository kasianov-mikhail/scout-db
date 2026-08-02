//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

@testable import ScoutDB

extension ReadOperation {
    /// A read over the entity's current schema, for tests that drive the
    /// operation directly instead of going through a query builder.
    init(store: EntityStore, entity: String, branches: [[ClientFilter]] = [[]], sort: [EntityStore.Sort] = [])
        async throws
    {
        self.init(
            database: store.database,
            definition: try await store.registry.definition(for: entity),
            branches: branches,
            sort: sort
        )
    }
}
