//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func fold(
        of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, any branches: [[Filter]]
    ) async throws -> [String: GridFold]? {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = FilterPlan(any: branches) else {
            return nil
        }

        query.expandRange(in: definition)

        guard query.numericField == nil else {
            return nil
        }

        return try await gridFold(
            query,
            of: field,
            folding: kind,
            by: group,
            entity: entity,
            in: definition
        )
    }
}
