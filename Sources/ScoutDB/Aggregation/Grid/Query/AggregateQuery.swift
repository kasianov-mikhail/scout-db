//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct AggregateQuery {
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

        let kind = declared.metricKind

        let records = try await store.database.allRecords(
            matching: .grid(entity: entity, view: view, group: group)
        )

        var totals: [String: AggregateTotal] = [:]

        for record in records {
            guard let key = record[CKRecord.groupCell] as? String else {
                continue
            }

            let count = Int(record[CKRecord.countCell] as? Int64 ?? 0)
            let value = kind == nil ? nil : record[CKRecord.valueCell] as? Double

            guard count != 0 || value != nil else {
                continue
            }

            let merged = totals[key]

            totals[key] = AggregateTotal(
                group: key,
                count: (merged?.count ?? 0) + count,
                value: kind?.accumulate(merged?.value, value) ?? merged?.value
            )
        }

        return totals.values.sorted()
    }
}
