//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CoreLocation
import Foundation

extension EntityStore {
    func explain(entity: String, filters: [Filter] = [], sort: [Sort] = [], createdBy creator: String? = nil) async throws -> QueryPlan {
        let definition = try await registry.definition(for: entity)
        return try plan(filters, entity: entity, sort: sort, createdBy: creator, using: definition)
    }

    func explain(entity: String, any branches: [[Filter]], sort: [Sort] = [], createdBy creator: String? = nil) async throws -> [QueryPlan] {
        let definition = try await registry.definition(for: entity)
        return try branches.map { try plan($0, entity: entity, sort: sort, createdBy: creator, using: definition) }
    }

    private func plan(_ filters: [Filter], entity: String, sort: [Sort], createdBy creator: String?, using definition: EntityDefinition) throws -> QueryPlan {
        let (server, client) = try split(filters, entity: entity, using: definition)
        let scoped = server + (creator.map { [ServerFilter(field: "creatorUserRecordID", op: .equals, value: .reference($0))] } ?? [])
        return QueryPlan(
            server: scoped.map { "\($0.field) \($0.op.rawValue) \($0.value.canonical)" },
            client: client.map { "\($0.field) \($0.op) \($0.value.canonical)" },
            sort: try serverSort(sort, using: definition).map { "\($0.field) \($0.ascending ? "asc" : "desc")" }
        )
    }

    public enum Match: Equatable, Sendable {
        case equals, notEquals
        case greaterThan, greaterThanOrEquals, lessThan, lessThanOrEquals
        case `in`, notIn, beginsWith, contains, near, search
        case endsWith, like, matches
        case isNull, isNotNull

        var serverOperator: ServerFilter.Operator? {
            switch self {
            case .equals:
                .equals
            case .notEquals:
                .notEquals
            case .greaterThan:
                .greaterThan
            case .greaterThanOrEquals:
                .greaterThanOrEquals
            case .lessThan:
                .lessThan
            case .lessThanOrEquals:
                .lessThanOrEquals
            case .in:
                .in
            case .notIn:
                .notIn
            case .beginsWith:
                .beginsWith
            case .contains:
                .contains
            case .near:
                .near
            case .search:
                .search
            case .endsWith, .like, .matches, .isNull, .isNotNull:
                nil
            }
        }

        var complement: Match? {
            switch self {
            case .equals:
                .notEquals
            case .notEquals:
                .equals
            case .in:
                .notIn
            case .notIn:
                .in
            case .greaterThan:
                .lessThanOrEquals
            case .greaterThanOrEquals:
                .lessThan
            case .lessThan:
                .greaterThanOrEquals
            case .lessThanOrEquals:
                .greaterThan
            default:
                nil
            }
        }
    }

    private static func serverComplement(of filter: Filter, in field: FieldDefinition) -> ServerFilter? {
        guard let op = filter.op.complement?.serverOperator, field.alwaysPresent else {
            return nil
        }
        guard case .slot(let pool, let slot) = field.storage, pool.isQueryable else {
            return nil
        }
        return ServerFilter(field: slot, op: op, value: filter.value)
    }

    static func ordered(_ lhs: EntityRecord, _ rhs: EntityRecord, by sorts: [Sort]) -> Bool {
        for sort in sorts {
            let order: ComparisonResult
            if case .location(let latitude, let longitude)? = sort.origin {
                order = rankDistance(lhs.values[sort.field], rhs.values[sort.field], from: CLLocation(latitude: latitude, longitude: longitude))
            } else {
                order = rank(lhs.values[sort.field], rhs.values[sort.field])
            }
            guard order != .orderedSame else {
                continue
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return false
    }

    private static func rankDistance(_ lhs: RecordValue?, _ rhs: RecordValue?, from origin: CLLocation) -> ComparisonResult {
        func distance(_ value: RecordValue?) -> Double {
            guard case .location(let latitude, let longitude)? = value else {
                return .greatestFiniteMagnitude
            }
            return CLLocation(latitude: latitude, longitude: longitude).distance(from: origin)
        }
        return order(distance(lhs), distance(rhs))
    }

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
        try filters.map { filter -> (EntityRecord) -> Bool in
            let base = try matcher(for: filter)
            return filter.negated ? { !base($0) } : base
        }
    }

    func split(_ filters: [Filter], entity: String, using definition: EntityDefinition) throws -> (server: [ServerFilter], client: [Filter]) {
        var server = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]
        var client: [Filter] = []
        let fields = definition.fields(at: definition.version)
        let byName = definition.fieldsByName(at: definition.version)

        for filter in filters {
            guard let field = byName[filter.field] else {
                throw SchemaError.unknownField(filter.field)
            }
            if filter.negated {
                guard filter.op != .near, filter.op != .search else {
                    throw SchemaError.invalidValue(filter.field)
                }
                if let complement = Self.serverComplement(of: filter, in: field) {
                    server.append(complement)
                } else {
                    client.append(filter)
                }
                continue
            }
            switch filter.op {
            case .isNull, .isNotNull, .matches:
                client.append(filter)
            case .contains where !field.type.isList:
                if case .string(let needle) = filter.value {
                    server += ngramPrefilter(for: [needle], of: field, in: fields)
                }
                client.append(filter)
            case .like:
                if case .string(let pattern) = filter.value {
                    let literals = pattern.split { $0 == "*" || $0 == "?" }.map(String.init)
                    server += ngramPrefilter(for: literals, of: field, in: fields)
                }
                client.append(filter)
            case .endsWith:
                if case .slot(_, let slot)? = reversedShadow(of: field, in: fields)?.storage, case .string(let suffix) = filter.value {
                    server.append(ServerFilter(field: slot, op: .beginsWith, value: .string(String(suffix.reversed()))))
                } else {
                    client.append(filter)
                }
            case .search:
                guard field.type == .text, case .slot(_, let slot) = field.storage else {
                    throw SchemaError.invalidValue(filter.field)
                }
                server.append(ServerFilter(field: slot, op: .search, value: filter.value))
                client.append(filter)
            default:
                guard let op = filter.op.serverOperator else {
                    throw SchemaError.unknownField(filter.field)
                }
                guard case .slot(let pool, let slot) = field.storage else {
                    guard filter.op != .near else {
                        throw SchemaError.invalidValue(filter.field)
                    }
                    client.append(filter)
                    continue
                }
                guard pool.isQueryable else {
                    throw SchemaError.invalidValue(filter.field)
                }
                server.append(ServerFilter(field: slot, op: op, value: filter.value, radius: filter.radius))
            }
        }
        return (server, client)
    }

    func serverSort(_ sort: [Sort], using definition: EntityDefinition) throws -> [ServerSort] {
        try sort.map { sort in
            guard let field = definition.field(named: sort.field, at: definition.version), case .slot(let pool, let slot) = field.storage else {
                throw SchemaError.unknownField(sort.field)
            }
            if sort.origin != nil, field.type != .location {
                throw SchemaError.invalidValue(sort.field)
            }
            if sort.origin == nil, !pool.isSortable {
                throw SchemaError.invalidValue(sort.field)
            }
            return ServerSort(field: slot, ascending: sort.ascending, origin: sort.origin)
        }
    }

    static func matcher(for filter: Filter) throws -> (EntityRecord) -> Bool {
        let field = filter.field
        switch filter.op {
        case .isNull:
            return { $0.values[field] == nil }
        case .isNotNull:
            return { $0.values[field] != nil }
        case .equals:
            return { $0.values[field] == filter.value }
        case .notEquals:
            return { $0.values[field].map { $0 != filter.value } ?? false }
        case .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            return comparisonMatcher(for: filter)
        case .in:
            let options = filter.value.members ?? [filter.value]
            return { $0.values[field].map(options.contains) ?? false }
        case .notIn:
            let options = filter.value.members ?? [filter.value]
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
        case .endsWith:
            guard case .string(let suffix) = filter.value else {
                return { _ in false }
            }
            return stringMatcher(field) { $0.hasSuffix(suffix) }
        case .like:
            guard case .string(let pattern) = filter.value else {
                return { _ in false }
            }
            guard let regex = try? Regex(wildcardPattern(pattern)) else {
                throw SchemaError.invalidValue(filter.field)
            }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        case .matches:
            guard case .string(let pattern) = filter.value else {
                return { _ in false }
            }
            guard let regex = try? Regex(pattern) else {
                throw SchemaError.invalidValue(filter.field)
            }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        case .search:
            guard case .string(let needle) = filter.value else {
                return { _ in false }
            }
            let needles = needle.lowercased().split { !$0.isLetter && !$0.isNumber }
            return stringMatcher(field) { text in
                let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber })
                return needles.allSatisfy(tokens.contains)
            }
        default:
            return { _ in false }
        }
    }

    private static func comparisonMatcher(for filter: Filter) -> (EntityRecord) -> Bool {
        let field = filter.field
        return { record in
            guard let value = record.values[field], comparable(value, filter.value) else {
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

    private static func stringMatcher(_ field: String, _ predicate: @escaping (String) -> Bool) -> (EntityRecord) -> Bool {
        { record in
            guard case .string(let text)? = record.values[field] else {
                return false
            }
            return predicate(text)
        }
    }

    fileprivate static func wildcardPattern(_ pattern: String) -> String {
        pattern.map { character -> String in
            switch character {
            case "*":
                ".*"
            case "?":
                "."
            default:
                NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
    }

    private func reversedShadow(of field: FieldDefinition, in fields: [FieldDefinition]) -> FieldDefinition? {
        fields.first { $0.derived == Derivation(source: field.name, transform: .reversed) }
    }

    private func ngramPrefilter(for needles: [String], of field: FieldDefinition, in fields: [FieldDefinition]) -> [ServerFilter] {
        let shadow = fields.first { $0.derived == Derivation(source: field.name, transform: .ngrams) }
        guard case .slot(_, let slot)? = shadow?.storage else {
            return []
        }

        return needles.flatMap { needle in
            let folded = needle.folded
            guard folded.count >= 3 else {
                return [ServerFilter]()
            }
            return EntityCoder.trigrams(of: folded).map {
                ServerFilter(field: slot, op: .contains, value: .string($0))
            }
        }
    }
}
