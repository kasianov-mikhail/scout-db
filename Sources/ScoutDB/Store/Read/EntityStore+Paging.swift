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

        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask {
                    try await self.fieldPage(
                        entity: entity,
                        filters: branch,
                        field: field,
                        descending: descending,
                        cursor: cursor,
                        limit: limit,
                        using: definition
                    )
                }
            }
            return try await group.reduce(into: [[EntityRecord]]()) { $0.append($1) }
        }

        var seen: Set<String> = []
        let records = Array(
            pages.flatMap { $0 }
                .sorted { precedes($0, $1, by: field, descending: descending) }
                .filter { seen.insert($0.uuid).inserted }
                .prefix(limit))

        let next: FieldCursor? =
            records.count == limit
            ? records.last.flatMap { record in record.values[field].map { FieldCursor(value: $0, uuid: record.uuid) } }
            : nil

        return FieldPage(records: records, cursor: next)
    }

    private func fieldPage(
        entity: String, filters: [Filter], field: String, descending: Bool, cursor: FieldCursor?, limit: Int, using definition: EntityDefinition
    ) async throws -> [EntityRecord] {
        var pageFilters = filters

        if let cursor {
            pageFilters.append(
                Filter(
                    field: field,
                    op: descending ? .lessThanOrEquals : .greaterThanOrEquals,
                    value: cursor.value
                )
            )
        }

        let sort =
            try serverSort(
                [Sort(field: field, ascending: !descending)],
                using: definition
            ) + [uuidSort]

        let (query, included) = try liveQuery(
            pageFilters,
            entity: entity,
            sort: sort,
            using: definition
        )

        let collected = try await boundedRecords(
            matching: query,
            desiredKeys: nil,
            limit: limit,
            using: definition
        ) { record in
            guard included(record), record.values[field] != nil else {
                return false
            }
            guard let cursor else {
                return true
            }
            return beyond(record, field, cursor, descending: descending)
        }

        return Array(
            collected.sorted {
                precedes($0, $1, by: field, descending: descending)
            }
            .prefix(limit))
    }
}

private func beyond(_ record: EntityRecord, _ field: String, _ cursor: FieldCursor, descending: Bool) -> Bool {
    switch EntityStore.rank(record.values[field], cursor.value) {
    case .orderedSame:
        record.uuid > cursor.uuid
    case .orderedAscending:
        descending
    case .orderedDescending:
        !descending
    }
}

private func precedes(_ lhs: EntityRecord, _ rhs: EntityRecord, by field: String, descending: Bool) -> Bool {
    let order = EntityStore.rank(lhs.values[field], rhs.values[field])
    guard order != .orderedSame else {
        return lhs.uuid < rhs.uuid
    }
    return descending ? order == .orderedDescending : order == .orderedAscending
}

private let uuidSort = ServerSort(field: "uuid", ascending: true)
