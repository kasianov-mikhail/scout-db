//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct PageOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let field: String
    let order: SortOrder
    let fields: [String]?

    private var ranking: [FieldOrder] {
        [FieldOrder(key: .field(field), order: order), FieldOrder(key: .uuid)]
    }

    func records(branches: [[ClientFilter]], size: Int, cursor: FieldCursor?) async throws -> FieldPage {
        let pages = try await branches.orderedBatches { branch in
            try await self.records(filters: branch, size: size, cursor: cursor)
        }

        let records = pages.distinct.ranked(using: ranking, limit: size)

        guard records.count == size, let last = records.last, let value = last.values[field] else {
            return FieldPage(records: records, cursor: nil)
        }
        return FieldPage(records: records, cursor: FieldCursor(value: value, uuid: last.uuid))
    }

    private func records(filters: [ClientFilter], size: Int, cursor: FieldCursor?) async throws -> [EntityRecord] {
        var pageFilters = filters

        if let cursor {
            pageFilters.append(
                ClientFilter(
                    field: field,
                    op: order == .reverse ? .lessThanOrEquals : .greaterThanOrEquals,
                    value: cursor.value
                )
            )
        }

        let sort =
            try definition.serverSort(
                [EntityStore.Sort(field: field, order: order)]
            ) + [CKQuery.Sort(field: Envelope.uuid, order: .forward)]

        var plan = try definition.plan(
            matching: pageFilters,
            sort: sort,
            fields: fields.map { $0 + [field] }
        )

        plan.included = { record in
            guard record.values[field] != nil else {
                return false
            }
            guard let cursor else {
                return true
            }
            return beyond(record, cursor)
        }

        return try await database.scan(
            matching: plan,
            limit: size,
            using: definition
        )
        .ranked(using: ranking, limit: size)
    }

    private func beyond(_ record: EntityRecord, _ cursor: FieldCursor) -> Bool {
        switch RecordValue.rank(record.values[field], cursor.value) {
        case .orderedSame:
            record.uuid > cursor.uuid
        case .orderedAscending:
            order == .reverse
        case .orderedDescending:
            order == .forward
        }
    }
}

extension QueryBuilder {
    var page: PageOperation {
        get async throws {
            guard sorts.count == 1, let sort = sorts.first else {
                throw SchemaError.unsupportedQuery(.singleSortRequired)
            }

            let definition = try await self.definition
            let target = try definition.field(sort.field, at: definition.version)

            guard [.string, .int, .double, .timestamp].contains(target.type) else {
                throw SchemaError.unsupportedQuery(.unpageableField(sort.field))
            }
            guard case .slot = target.storage else {
                throw SchemaError.unsupportedQuery(.unpageableField(sort.field))
            }

            return PageOperation(
                database: store.database,
                definition: definition,
                field: sort.field,
                order: sort.order,
                fields: selection
            )
        }
    }
}
