//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    func serverFilters(_ filters: [Filter]) throws -> [ServerFilter] {
        var server = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]

        let byName = fieldsByName(at: version)

        for filter in filters {
            guard let field = byName[filter.field] else {
                throw SchemaError.unknownField(filter.field)
            }

            switch filter.op {
            case .contains where !field.type.isList:
                continue

            case .search:
                guard field.type == .text, case .slot(_, let slot) = field.storage else {
                    throw SchemaError.invalidValue(filter.field)
                }
                server.append(ServerFilter(field: slot, op: .search, value: filter.value))

            default:
                guard case .slot(_, let slot) = field.storage else {
                    continue
                }
                server.append(ServerFilter(field: slot, op: filter.op, value: filter.value))
            }
        }

        return server
    }

    func clientFilters(_ filters: [Filter]) throws -> [Filter] {
        let byName = fieldsByName(at: version)

        return try filters.filter { filter in
            guard let field = byName[filter.field] else {
                throw SchemaError.unknownField(filter.field)
            }

            switch filter.op {
            case .contains where !field.type.isList:
                return true

            case .search:
                guard field.type == .text, case .slot = field.storage else {
                    throw SchemaError.invalidValue(filter.field)
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

    func serverSort(_ sort: [EntityStore.Sort]) throws -> [ServerSort] {
        try sort.map { sort in
            guard let field = field(named: sort.field, at: version) else {
                throw SchemaError.unknownField(sort.field)
            }
            guard case .slot(let pool, let slot) = field.storage else {
                throw SchemaError.unknownField(sort.field)
            }
            guard pool.isSortable else {
                throw SchemaError.invalidValue(sort.field)
            }

            return ServerSort(field: slot, ascending: sort.ascending)
        }
    }
}
