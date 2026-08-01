//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func read(entity: String, any branches: [[Filter]] = [[]], sort: [Sort] = [], limit: Int? = nil)
        async throws -> [EntityRecord]
    {
        let reader = BranchReader(
            database: database,
            entity: entity,
            sort: sort,
            limit: limit,
            definition: try await registry.definition(for: entity)
        )
        return try await reader.read(any: branches)
    }
}
