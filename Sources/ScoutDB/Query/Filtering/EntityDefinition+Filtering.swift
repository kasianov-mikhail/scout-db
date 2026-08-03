//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityDefinition {
    func serverFilters(_ filters: [ClientFilter]) throws -> [CKQuery.Filter] {
        var server = [CKQuery.Filter(field: "entity", op: .equals, value: .string(entity))]

        for filter in filters {
            let field = try field(filter.field, at: version)

            switch filter.op {
            case .contains where !field.type.isList:
                continue

            case .search:
                guard field.type == .text, case .slot(_, let slot) = field.storage else {
                    throw SchemaError.unsupportedQuery(.unsearchableField(filter.field))
                }
                server.append(CKQuery.Filter(field: slot, op: .search, value: filter.value))

            default:
                guard case .slot(_, let slot) = field.storage else {
                    continue
                }
                server.append(CKQuery.Filter(field: slot, op: filter.op, value: filter.value))
            }
        }

        return server
    }

    func clientFilters(_ filters: [ClientFilter]) throws -> [ClientFilter] {
        try filters.filter { filter in
            let field = try field(filter.field, at: version)

            switch filter.op {
            case .contains where !field.type.isList:
                return true

            case .search:
                guard field.type == .text, case .slot = field.storage else {
                    throw SchemaError.unsupportedQuery(.unsearchableField(filter.field))
                }
                return true

            default:
                guard case .slot = field.storage else {
                    return true
                }
                return false
            }
        }
    }

    func serverSort(_ sort: [EntityStore.Sort]) throws -> [CKQuery.Sort] {
        try sort.map { sort in
            let field = try field(sort.field, at: version)

            guard case .slot(let pool, let slot) = field.storage else {
                throw SchemaError.unknownField(sort.field)
            }
            guard pool.isSortable else {
                throw SchemaError.unsupportedQuery(.unsortableField(sort.field))
            }

            return CKQuery.Sort(field: slot, order: sort.order)
        }
    }
}
