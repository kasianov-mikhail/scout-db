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
            database: database,
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
