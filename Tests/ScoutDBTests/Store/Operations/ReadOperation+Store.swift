//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

@testable import ScoutDB

extension ReadOperation {
    init(store: EntityStore, entity: String, branches: [[ClientFilter]] = [[]], sort: [EntityStore.Sort] = [])
        async throws
    {
        self.init(
            database: store.database,
            definition: try await store.registry.definition(entity: entity),
            branches: branches,
            sort: sort,
            fields: nil
        )
    }
}
