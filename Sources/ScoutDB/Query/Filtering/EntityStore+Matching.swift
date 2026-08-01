//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    static func rank(_ lhs: RecordValue?, _ rhs: RecordValue?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (.string(let lhs)?, .string(let rhs)?):
            return order(lhs, rhs)
        case (.date(let lhs)?, .date(let rhs)?):
            return order(lhs, rhs)
        default:
            guard let lhs = lhs?.scalar, let rhs = rhs?.scalar else {
                return .orderedSame
            }
            return order(lhs, rhs)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    static func matchers(for filters: [Filter]) throws -> [(EntityRecord) -> Bool] {
        try filters.map { try matcher(for: $0) }
    }

    func serverFilters(_ filters: [Filter], entity: String, using definition: EntityDefinition) throws
        -> [ServerFilter]
    {
        var server = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]

        let byName = definition.fieldsByName(at: definition.version)

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

    func clientFilters(_ filters: [Filter], using definition: EntityDefinition) throws -> [Filter] {
        let byName = definition.fieldsByName(at: definition.version)

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

    func serverSort(_ sort: [Sort], using definition: EntityDefinition) throws -> [ServerSort] {
        try sort.map { sort in
            guard let field = definition.field(named: sort.field, at: definition.version) else {
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

    private static func matcher(for filter: Filter) throws -> (EntityRecord) -> Bool {
        let field = filter.field
        switch filter.op {
        case .equals:
            return { $0.values[field] == filter.value }

        case .notEquals:
            return { $0.values[field].map { $0 != filter.value } ?? false }

        case .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            return comparisonMatcher(for: filter)

        case .in:
            let options = Set(filter.value.members ?? [filter.value])
            return { $0.values[field].map(options.contains) ?? false }

        case .notIn:
            let options = Set(filter.value.members ?? [filter.value])
            return { record in record.values[field].map { !options.contains($0) } ?? false }

        case .beginsWith:
            guard case .string(let prefix) = filter.value else {
                return { _ in false }
            }
            return stringMatcher(field) { $0.hasPrefix(prefix) }

        case .contains:
            guard case .string(let needle) = filter.value else {
                return { _ in false }
            }
            return { record in
                switch record.values[field] {
                case .string(let text)?:
                    text.contains(needle)
                case .strings(let members)?:
                    members.contains(needle)
                default:
                    false
                }
            }

        case .search:
            guard case .string(let needle) = filter.value else {
                return { _ in false }
            }
            let needles = needle.lowercased().split {
                !$0.isLetter && !$0.isNumber
            }
            return stringMatcher(field) { text in
                let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber })
                return needles.allSatisfy(tokens.contains)
            }
        }
    }

    private static func comparisonMatcher(for filter: Filter) -> (EntityRecord) -> Bool {
        { record in
            guard let value = record.values[filter.field], comparable(value, filter.value) else {
                return false
            }
            return switch (filter.op, rank(value, filter.value)) {
            case (.greaterThan, .orderedDescending), (.lessThan, .orderedAscending):
                true
            case (.greaterThanOrEquals, .orderedDescending), (.greaterThanOrEquals, .orderedSame):
                true
            case (.lessThanOrEquals, .orderedAscending), (.lessThanOrEquals, .orderedSame):
                true
            default:
                false
            }
        }
    }

    private static func comparable(_ lhs: RecordValue, _ rhs: RecordValue) -> Bool {
        switch (lhs, rhs) {
        case (.string, .string), (.date, .date):
            true
        default:
            lhs.scalar != nil && rhs.scalar != nil
        }
    }

    private static func stringMatcher(_ field: String, _ predicate: @escaping (String) -> Bool) -> (EntityRecord) ->
        Bool
    {
        { record in
            guard case .string(let text)? = record.values[field] else {
                return false
            }
            return predicate(text)
        }
    }
}
