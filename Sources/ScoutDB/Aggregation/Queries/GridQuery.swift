//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct GridQuery {
    let store: EntityStore
    let entity: String
    let view: String
    var group: String?

    init(_ store: EntityStore, entity: String, view: String, group: String? = nil) {
        self.store = store
        self.entity = entity
        self.view = view
        self.group = group
    }

    func totals() async throws -> [AggregateTotal] {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view) else {
            throw SchemaError.unknownField(view)
        }

        let kind = declared.metric?.kind

        let records = try await store.grid(
            entity: entity,
            view: view,
            group: group,
            values: kind != nil
        )

        var totals: [String: AggregateTotal] = [:]

        for record in records {
            guard let key = record["group_key"] as? String else {
                continue
            }

            let count = Int(record.cellCount)
            let value = kind == nil ? nil : record.cellValue

            guard count != 0 || value != nil else {
                continue
            }

            let merged = totals[key]

            totals[key] = AggregateTotal(
                group: key,
                count: (merged?.count ?? 0) + count,
                value: combined(merged?.value, value, kind)
            )
        }

        return totals.values.sorted()
    }
}

private func combined(_ lhs: Double?, _ rhs: Double?, _ kind: Metric?) -> Double? {
    guard let lhs else {
        return rhs
    }
    guard let rhs else {
        return lhs
    }
    return kind?.combine(lhs, rhs) ?? lhs + rhs
}
