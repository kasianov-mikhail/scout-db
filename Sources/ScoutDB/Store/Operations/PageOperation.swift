//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct PageOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let field: String
    let descending: Bool

    private var order: [FieldOrder] {
        [FieldOrder(key: .field(field), order: descending ? .reverse : .forward), FieldOrder(key: .uuid)]
    }

    func records(branches: [[ClientFilter]], size: Int, cursor: FieldCursor?) async throws -> FieldPage {
        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask {
                    try await self.records(matching: branch, size: size, cursor: cursor)
                }
            }
            return try await group.reduce(into: [EntityRecord]()) { $0 += $1 }
        }

        let records = pages.unique().ranked(using: order, limit: size)

        let next: FieldCursor? =
            records.count == size
            ? records.last.flatMap { record in record.values[field].map { FieldCursor(value: $0, uuid: record.uuid) } }
            : nil

        return FieldPage(records: records, cursor: next)
    }

    private func records(matching filters: [ClientFilter], size: Int, cursor: FieldCursor?) async throws
        -> [EntityRecord]
    {
        var pageFilters = filters

        if let cursor {
            pageFilters.append(
                ClientFilter(
                    field: field,
                    op: descending ? .lessThanOrEquals : .greaterThanOrEquals,
                    value: cursor.value
                )
            )
        }

        let sort =
            try definition.serverSort(
                [EntityStore.Sort(field: field, ascending: !descending)]
            ) + [CKQuery.Sort(field: "uuid", order: .forward)]

        let plan = try definition.plan(matching: pageFilters, sort: sort)

        let collected = try await database.scan(
            matching: plan.query,
            limit: size,
            using: definition
        ) { record in
            guard plan.includes(record), record.values[field] != nil else {
                return false
            }
            guard let cursor else {
                return true
            }
            return beyond(record, cursor)
        }

        return collected.ranked(using: order, limit: size)
    }

    private func beyond(_ record: EntityRecord, _ cursor: FieldCursor) -> Bool {
        switch RecordValue.rank(record.values[field], cursor.value) {
        case .orderedSame:
            record.uuid > cursor.uuid
        case .orderedAscending:
            descending
        case .orderedDescending:
            !descending
        }
    }
}

extension QueryBuilder {
    var page: PageOperation {
        get async throws {
            guard sorts.count == 1, let sort = sorts.first else {
                throw SchemaError.unsupportedQuery(.singleSortRequired)
            }

            let definition = try await store.registry.definition(for: entity)
            let target = try definition.field(sort.field)

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
                descending: !sort.ascending
            )
        }
    }
}
