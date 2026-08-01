//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func read(
        entity: String, any branches: [[Filter]] = [[]], orderedBy field: String, descending: Bool = false, limit: Int,
        after cursor: FieldCursor? = nil
    ) async throws -> FieldPage {
        let definition = try await registry.definition(for: entity)

        guard let target = definition.field(named: field, at: definition.version) else {
            throw SchemaError.invalidValue(field)
        }
        guard [.string, .int, .double, .timestamp].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        guard case .slot = target.storage else {
            throw SchemaError.invalidValue(field)
        }

        let pager = FieldPager(
            store: self,
            entity: entity,
            field: field,
            descending: descending,
            limit: limit,
            cursor: cursor,
            definition: definition
        )
        return try await pager.page(any: branches)
    }
}

private struct FieldPager: Sendable {
    let store: EntityStore
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
            try store.serverSort(
                [EntityStore.Sort(field: field, ascending: !descending)],
                using: definition
            ) + [ServerSort(field: "uuid", ascending: true)]

        let query = try store.liveQuery(
            pageFilters,
            entity: entity,
            sort: sort,
            using: definition
        )
        let included = try store.liveFilter(pageFilters, using: definition)

        let collected = try await store.boundedRecords(
            matching: query,
            limit: limit,
            using: definition
        ) { record in
            guard included(record), record.values[field] != nil else {
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
        switch EntityStore.rank(record.values[field], cursor.value) {
        case .orderedSame:
            record.uuid > cursor.uuid
        case .orderedAscending:
            descending
        case .orderedDescending:
            !descending
        }
    }
}
