//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct RecordFold {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let aggregate: AggregateDefinition
    let date: String
    let since: Date

    func rows(groups: [String]?, range: Range<Date>?) async throws -> [VectorRow] {
        var filters = [
            ClientFilter(
                field: date,
                op: .lessThan,
                value: .date(min(range?.upperBound ?? since, since))
            )
        ]

        if let lower = range?.lowerBound {
            filters.append(
                ClientFilter(
                    field: date,
                    op: .greaterThanOrEquals,
                    value: .date(lower)
                )
            )
        }

        let fields = [
            date,
            aggregate.groupBy,
            aggregate.measure?.field,
            aggregate.measure?.histogram?.field,
        ]

        let records = try await ReadOperation(
            database: database,
            definition: definition,
            branches: [filters],
            sort: [],
            fields: fields.compactMap(\.self)
        )
        .records()

        return ShardLayout([ShardPlan(aggregate: aggregate, head: nil)]).deltas(old: [], new: records, now: since)
            .filter {
                slot, _ in groups?.contains(slot.group) ?? true
            }
            .map { slot, delta in
                let record = CKRecord(recordType: VectorSlot.recordType, recordID: slot.recordID)
                delta.apply(record: record)
                return VectorRow(group: slot.group, week: slot.week, record: record)
            }
    }
}
