//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func count(entity: String, any branches: [[Filter]]) async throws -> Int? {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = CountQuery(any: branches) else {
            return nil
        }

        query.key(in: definition)

        guard query.numericField == nil else {
            return nil
        }
        guard let folded = try await gridFold(query, of: nil, by: nil, entity: entity, in: definition) else {
            return nil
        }
        return folded.values.reduce(0) { $0 + $1.count }
    }
}
