//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct EntityPager: Sendable {
    let database: any CloudDatabase
    let entity: String
    let field: String
    let descending: Bool
    let limit: Int
    let cursor: FieldCursor?
    let definition: EntityDefinition

    private var order: [FieldOrder] {
        [.field(field, descending ? .reverse : .forward), .uuid]
    }

    func page(any branches: [[EntityStore.Filter]]) async throws -> FieldPage {
        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask {
                    try await self.page(matching: branch)
                }
            }
            return try await group.reduce(into: [EntityRecord]()) { $0 += $1 }
        }

        var seen: Set<String> = []
        let records = Array(
            pages.sorted(using: order)
                .filter { seen.insert($0.uuid).inserted }
                .prefix(limit)
        )

        let next: FieldCursor? =
            records.count == limit
            ? records.last.flatMap { record in record.values[field].map { FieldCursor(value: $0, uuid: record.uuid) } }
            : nil

        return FieldPage(records: records, cursor: next)
    }

    private func page(matching filters: [EntityStore.Filter]) async throws -> [EntityRecord] {
        var pageFilters = filters

        if let cursor {
            pageFilters.append(
                EntityStore.Filter(
                    field: field,
                    op: descending ? .lessThanOrEquals : .greaterThanOrEquals,
                    value: cursor.value
                )
            )
        }

        let sort =
            try definition.serverSort(
                [EntityStore.Sort(field: field, ascending: !descending)]
            ) + [ServerSort(field: "uuid", ascending: true)]

        let query = CKQuery(
            recordType: "Entity",
            filters: try definition.serverFilters(pageFilters),
            sort: sort
        )
        let matchers = try definition.clientFilters(pageFilters).map { $0.matcher() }

        let collected = try await database.boundedRecords(
            matching: query,
            limit: limit,
            using: definition
        ) { record in
            guard matchers.allSatisfy({ $0(record) }), record.values[field] != nil else {
                return false
            }
            guard let cursor else {
                return true
            }
            return beyond(record, cursor)
        }

        return Array(collected.sorted(using: order).prefix(limit))
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
