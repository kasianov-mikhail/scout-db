//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CoreLocation
import Foundation

extension EntityStore {
    public func explain(entity: String, filters: [Filter] = [], sort: [Sort] = []) async throws -> QueryPlan {
        let definition = try await registry.definition(for: entity)
        let (server, client) = try split(filters, entity: entity, using: definition)
        return QueryPlan(
            server: server.map { "\($0.field) \($0.op.rawValue) \($0.value.canonical)" },
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
            case .equals: .equals
            case .notEquals: .notEquals
            case .greaterThan: .greaterThan
            case .greaterThanOrEquals: .greaterThanOrEquals
            case .lessThan: .lessThan
            case .lessThanOrEquals: .lessThanOrEquals
            case .in: .in
            case .notIn: .notIn
            case .beginsWith: .beginsWith
            case .contains: .contains
            case .near: .near
            case .search: .search
            case .endsWith, .like, .matches, .isNull, .isNotNull: nil
            }
        }
    }

    static func ordered(_ lhs: EntityRecord, _ rhs: EntityRecord, by sorts: [Sort]) -> Bool {
        for sort in sorts {
            let order: ComparisonResult
            if case .location(let latitude, let longitude)? = sort.origin {
                order = rankDistance(lhs.values[sort.field], rhs.values[sort.field], from: CLLocation(latitude: latitude, longitude: longitude))
            } else {
                order = rank(lhs.values[sort.field], rhs.values[sort.field])
            }
            guard order != .orderedSame else { continue }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return false
    }

    // Distance ranking for a nearest-first sort; a record without the location
    // ranks last, mirroring the server pushing unlocatable rows to the end.
    private static func rankDistance(_ lhs: RecordValue?, _ rhs: RecordValue?, from origin: CLLocation) -> ComparisonResult {
        func distance(_ value: RecordValue?) -> Double {
            guard case .location(let latitude, let longitude)? = value else { return .greatestFiniteMagnitude }
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
            guard let lhs = lhs?.scalar, let rhs = rhs?.scalar else { return .orderedSame }
            return order(lhs, rhs)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    // Splits logical filters into predicates CloudKit can run and matchers the
    // store applies after decoding. `contains` is server-side list membership but a
    // client-side substring check on strings; `endsWith` runs server-side when the
    // definition declares a `reversed` shadow of the field, and falls back otherwise.
    func split(_ filters: [Filter], entity: String, using definition: EntityDefinition) throws -> (server: [ServerFilter], client: [Filter]) {
        var server = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]
        var client: [Filter] = []
        let fields = definition.fields(at: definition.version)
        let byName = definition.fieldsByName(at: definition.version)

        for filter in filters {
            guard let field = byName[filter.field] else {
                throw SchemaError.unknownField(filter.field)
            }
            // A negation runs as the complement of the client matcher; the ngram
            // and shadow-slot narrowings below only ever shrink the positive set,
            // so they must not apply to a negated filter.
            if filter.negated {
                guard filter.op != .near, filter.op != .search else {
                    throw SchemaError.invalidValue(filter.field)
                }
                client.append(filter)
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
                // The server's token search spans every field of the record
                // (`self CONTAINS`), so the named field re-narrows client-side.
                server.append(ServerFilter(field: slot, op: .search, value: filter.value))
                client.append(filter)
            default:
                guard let op = filter.op.serverOperator else {
                    throw SchemaError.unknownField(filter.field)
                }
                guard case .slot(_, let slot) = field.storage else {
                    // A payload field has no queryable slot, so every comparison the
                    // store can express post-decode falls back to a client matcher.
                    // Distance needs the server and keeps requiring a slot.
                    guard filter.op != .near else { throw SchemaError.invalidValue(filter.field) }
                    client.append(filter)
                    continue
                }
                server.append(ServerFilter(field: slot, op: op, value: filter.value, radius: filter.radius))
            }
        }
        return (server, client)
    }

    func serverSort(_ sort: [Sort], using definition: EntityDefinition) throws -> [ServerSort] {
        try sort.map { sort in
            guard let field = definition.field(named: sort.field, at: definition.version), case .slot(_, let slot) = field.storage else {
                throw SchemaError.unknownField(sort.field)
            }
            if sort.origin != nil, field.type != .location {
                throw SchemaError.invalidValue(sort.field)
            }
            return ServerSort(field: slot, ascending: sort.ascending, origin: sort.origin)
        }
    }

    // Compiles a client-side filter into a record predicate. Building the predicate
    // once per read hoists regex construction for `like` and `matches` out of the
    // per-record loop. A record missing the field never matches, mirroring the server.
    static func matcher(for filter: Filter) -> (EntityRecord) -> Bool {
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
            let options = options(of: filter.value)
            return { $0.values[field].map(options.contains) ?? false }
        case .notIn:
            let options = options(of: filter.value)
            return { record in record.values[field].map { !options.contains($0) } ?? false }
        case .beginsWith:
            guard case .string(let prefix) = filter.value else { return { _ in false } }
            return stringMatcher(field) { $0.hasPrefix(prefix) }
        case .contains:
            guard case .string(let needle) = filter.value else { return { _ in false } }
            return { record in
                switch record.values[field] {
                case .string(let text)?: text.contains(needle)
                case .strings(let members)?: members.contains(needle)
                default: false
                }
            }
        case .endsWith:
            guard case .string(let suffix) = filter.value else { return { _ in false } }
            return stringMatcher(field) { $0.hasSuffix(suffix) }
        case .like:
            guard case .string(let pattern) = filter.value, let regex = try? Regex(wildcardPattern(pattern)) else { return { _ in false } }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        case .matches:
            guard case .string(let pattern) = filter.value, let regex = try? Regex(pattern) else { return { _ in false } }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        case .search:
            // Token equality scoped to the named field, mirroring the server's
            // tokenization; every needle token must appear among the field's.
            guard case .string(let needle) = filter.value else { return { _ in false } }
            let needles = needle.lowercased().split { !$0.isLetter && !$0.isNumber }
            return stringMatcher(field) { text in
                let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber })
                return needles.allSatisfy(tokens.contains)
            }
        default:
            return { _ in false }
        }
    }

    // Ranking two values of different kinds is not meaningful, so a comparison
    // matches only comparable pairs: strings, dates, or numeric scalars.
    private static func comparisonMatcher(for filter: Filter) -> (EntityRecord) -> Bool {
        let field = filter.field
        return { record in
            guard let value = record.values[field], comparable(value, filter.value) else { return false }
            return switch (filter.op, rank(value, filter.value)) {
            case (.greaterThan, .orderedDescending), (.lessThan, .orderedAscending): true
            case (.greaterThanOrEquals, .orderedDescending), (.greaterThanOrEquals, .orderedSame): true
            case (.lessThanOrEquals, .orderedAscending), (.lessThanOrEquals, .orderedSame): true
            default: false
            }
        }
    }

    private static func comparable(_ lhs: RecordValue, _ rhs: RecordValue) -> Bool {
        switch (lhs, rhs) {
        case (.string, .string), (.date, .date): true
        default: lhs.scalar != nil && rhs.scalar != nil
        }
    }

    // The candidates of an `in`/`notIn` filter: the elements of a list value, or
    // the value itself as the single option.
    private static func options(of value: RecordValue) -> [RecordValue] {
        switch value {
        case .strings(let values): values.map(RecordValue.string)
        case .ints(let values): values.map(RecordValue.int)
        case .doubles(let values): values.map(RecordValue.double)
        case .dates(let values): values.map(RecordValue.date)
        default: [value]
        }
    }

    private static func stringMatcher(_ field: String, _ predicate: @escaping (String) -> Bool) -> (EntityRecord) -> Bool {
        { record in
            guard case .string(let text)? = record.values[field] else { return false }
            return predicate(text)
        }
    }

    // Translates `*`/`?` wildcards into an anchored regex pattern.
    static func wildcardPattern(_ pattern: String) -> String {
        pattern.map { character -> String in
            switch character {
            case "*": ".*"
            case "?": "."
            default: NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
    }

    private func reversedShadow(of field: FieldDefinition, in fields: [FieldDefinition]) -> FieldDefinition? {
        fields.first { $0.derived == Derivation(source: field.name, transform: .reversed) }
    }

    // The pg_trgm technique: an `ngrams` shadow slot lets the server narrow substring and
    // wildcard scans to records containing every trigram of the needle. The trigram match
    // is necessary but not sufficient, so the exact client-side matcher still runs after.
    private func ngramPrefilter(for needles: [String], of field: FieldDefinition, in fields: [FieldDefinition]) -> [ServerFilter] {
        let shadow = fields.first { $0.derived == Derivation(source: field.name, transform: .ngrams) }
        guard case .slot(_, let slot)? = shadow?.storage else { return [] }

        return needles.flatMap { needle in
            let folded = needle.folded
            guard folded.count >= 3 else { return [ServerFilter]() }
            return EntityCoder.trigrams(of: folded).map {
                ServerFilter(field: slot, op: .contains, value: .string($0))
            }
        }
    }
}
