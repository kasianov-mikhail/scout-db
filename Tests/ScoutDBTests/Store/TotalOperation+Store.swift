//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

@testable import ScoutDB

extension TotalOperation {
    init(store: EntityStore, entity: String, branches: [[ClientFilter]] = [[]]) async throws {
        self.init(
            database: store.database,
            definition: try await store.registry.definition(for: entity),
            branches: branches
        )
    }
}
