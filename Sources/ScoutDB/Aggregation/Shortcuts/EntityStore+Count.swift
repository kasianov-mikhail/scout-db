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

        guard definition.views?.isEmpty == false, var query = CountQuery(any: branches, envelopeDate: definition.envelopeDate) else {
            return nil
        }

        query.key(in: definition)

        if query.numericField != nil {
            guard query.from == nil, query.to == nil, let (view, cells) = query.histogramPlan(in: definition) else {
                return nil
            }

            let records = try await gridRecords(
                entity: entity,
                view: view.name,
                group: query.serverGroup,
                counts: cells
            )

            var total = 0
            for record in records {
                guard let key = record["group_key"] as? String, query.covers(key) else {
                    continue
                }
                for index in cells {
                    total += Int(record.count(at: index))
                }
            }
            return total
        }

        guard let folded = try await gridFold(query, of: nil, by: nil, entity: entity, in: definition) else {
            return nil
        }
        return folded.values.reduce(0) { $0 + $1.count }
    }
}
