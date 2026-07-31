//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension GridQuery {
    func totals() async throws -> [AggregateTotal] {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view) else {
            throw SchemaError.unknownField(view)
        }

        let kind = declared.metric?.kind
        let isStats = declared.stats != nil

        let records = try await store.grid(
            entity: entity,
            view: view,
            group: group,
            values: kind != nil,
            squares: isStats
        )

        var totals: [String: AggregateTotal] = [:]

        for record in records {
            guard let key = record["group_key"] as? String else {
                continue
            }

            let count = Int(record.cellCount)
            let value = kind == nil ? nil : record.cellValue
            let squares = isStats ? record.cellSquare : nil

            guard count != 0 || value != nil || squares != nil else {
                continue
            }

            let merged = totals[key]

            totals[key] = AggregateTotal(
                group: key,
                count: (merged?.count ?? 0) + count,
                value: combined(merged?.value, value, kind),
                squares: combined(merged?.squares, squares, nil)
            )
        }

        return totals.values.sorted()
    }
}
