//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func folder(entity: String, any branches: [[Filter]]) async throws -> GridFolder? {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = FilterPlan(any: branches) else {
            return nil
        }

        query.expandRange(in: definition)

        guard query.numericField == nil else {
            return nil
        }

        return GridFolder(
            database: database,
            entity: entity,
            definition: definition,
            query: query
        )
    }
}

struct GridFold: Sendable {
    let count: Int
    let value: Double?
}
