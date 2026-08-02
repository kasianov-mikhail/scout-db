//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct TotalOperation {
    let store: EntityStore
    let entity: String
    let aggregate: String
    var group: String?

    init(_ store: EntityStore, entity: String, aggregate: String, group: String? = nil) {
        self.store = store
        self.entity = entity
        self.aggregate = aggregate
        self.group = group
    }

    func totals() async throws -> [AggregateTotal] {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.aggregate(named: aggregate) else {
            throw SchemaError.unknownField(aggregate)
        }

        let kind = declared.metricKind

        let records = try await store.database.allRecords(
            matching: .grid(entity: entity, aggregate: aggregate, group: group)
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

extension TotalOperation {
    init(_ query: QueryBuilder, field: String?, group: String?) async throws {
        let store = query.store
        let definition = try await store.registry.definition(for: query.entity)

        guard let aggregate = definition.aggregate(grouping: group, folding: field) else {
            let shape = [
                group.map { "grouped by '\($0)'" },
                field.map { "folding '\($0)'" },
            ]
            throw SchemaError.invalidDefinition(
                "Entity '\(query.entity)' keeps no aggregate \(shape.compactMap { $0 }.joined(separator: ", "))"
            )
        }

        self.init(
            store,
            entity: query.entity,
            aggregate: aggregate.name,
            group: try query.narrowing(to: group)
        )
    }
}

extension QueryBuilder {
    fileprivate func narrowing(to group: String?) throws -> String? {
        guard let flat else {
            throw SchemaError.invalidDefinition("An aggregate reads the grid and cannot honor a disjunction")
        }

        var narrowed: String?
        for filter in flat {
            guard let group, filter.field == group, filter.op == .equals else {
                throw SchemaError.invalidDefinition(
                    "An aggregate reads the grid and can only be filtered by an equal '\(group ?? "group")'"
                )
            }
            narrowed = filter.value.canonical
        }
        return narrowed
    }
}
