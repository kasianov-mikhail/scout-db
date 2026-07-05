//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public struct QueryPlan: Equatable, Sendable, CustomStringConvertible {
    public let server: [String]
    public let client: [String]
    public let sort: [String]

    public var description: String {
        let lines = server.map { "SERVER \($0)" } + client.map { "CLIENT \($0)" } + sort.map { "SORT \($0)" }
        return lines.joined(separator: "\n")
    }
}

// The structured form of a server-side predicate, turned into an NSPredicate at
// the single point the store talks to CloudKit.
struct ServerFilter: Equatable, Sendable {
    enum Operator: String, Sendable {
        case equals
        case notEquals
        case greaterThan
        case greaterThanOrEquals
        case lessThan
        case lessThanOrEquals
        case `in`
        case notIn
        case beginsWith
        case contains
        case near
        case search
    }

    let field: String
    let op: Operator
    let value: RecordValue
    var radius: Double?

    var predicate: NSPredicate {
        let value = value.predicateValue
        return switch op {
        case .equals: NSPredicate(format: "%K == %@", field, value)
        case .notEquals: NSPredicate(format: "%K != %@", field, value)
        case .greaterThan: NSPredicate(format: "%K > %@", field, value)
        case .greaterThanOrEquals: NSPredicate(format: "%K >= %@", field, value)
        case .lessThan: NSPredicate(format: "%K < %@", field, value)
        case .lessThanOrEquals: NSPredicate(format: "%K <= %@", field, value)
        case .in: NSPredicate(format: "%K IN %@", field, value)
        case .notIn: NSPredicate(format: "NOT (%K IN %@)", field, value)
        case .beginsWith: NSPredicate(format: "%K BEGINSWITH %@", field, value)
        case .contains: NSPredicate(format: "%K CONTAINS %@", field, value)
        case .near: NSPredicate(format: "distanceToLocation:fromLocation:(%K, %@) < %f", field, value, radius ?? 0)
        case .search: NSPredicate(format: "self contains %@", value)
        }
    }
}

struct ServerSort: Equatable, Sendable {
    let field: String
    let ascending: Bool
}

func ckQuery(_ recordType: String, filters: [ServerFilter], sort: [ServerSort] = []) -> CKQuery {
    let predicate: NSPredicate =
        filters.isEmpty
        ? NSPredicate(value: true)
        : NSCompoundPredicate(type: .and, subpredicates: filters.map(\.predicate))
    let query = CKQuery(recordType: recordType, predicate: predicate)
    if sort.count > 0 {
        query.sortDescriptors = sort.map { NSSortDescriptor(key: $0.field, ascending: $0.ascending) }
    }
    return query
}

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
            let order = rank(lhs.values[sort.field], rhs.values[sort.field])
            guard order != .orderedSame else { continue }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return false
    }

    private static func rank(_ lhs: RecordValue?, _ rhs: RecordValue?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (.string(let lhs)?, .string(let rhs)?):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.date(let lhs)?, .date(let rhs)?):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        default:
            guard let lhs = lhs?.scalar, let rhs = rhs?.scalar else { return .orderedSame }
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
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
            default:
                guard let op = filter.op.serverOperator, case .slot(_, let slot) = field.storage else {
                    throw SchemaError.unknownField(filter.field)
                }
                server.append(ServerFilter(field: slot, op: op, value: filter.value, radius: filter.radius))
            }
        }
        return (server, client)
    }

    func serverSort(_ sort: [Sort], using definition: EntityDefinition) throws -> [ServerSort] {
        try sort.map { sort in
            guard case .slot(_, let slot)? = definition.field(named: sort.field, at: definition.version)?.storage else {
                throw SchemaError.unknownField(sort.field)
            }
            return ServerSort(field: slot, ascending: sort.ascending)
        }
    }

    // Compiles a client-side filter into a record predicate. Building the predicate
    // once per read hoists regex construction for `like` and `matches` out of the
    // per-record loop.
    static func matcher(for filter: Filter) -> (EntityRecord) -> Bool {
        let field = filter.field
        switch filter.op {
        case .isNull:
            return { $0.values[field] == nil }
        case .isNotNull:
            return { $0.values[field] != nil }
        case .contains:
            guard case .string(let needle) = filter.value else { return { _ in false } }
            return stringMatcher(field) { $0.contains(needle) }
        case .endsWith:
            guard case .string(let suffix) = filter.value else { return { _ in false } }
            return stringMatcher(field) { $0.hasSuffix(suffix) }
        case .like:
            guard case .string(let pattern) = filter.value, let regex = try? Regex(wildcardPattern(pattern)) else { return { _ in false } }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        case .matches:
            guard case .string(let pattern) = filter.value, let regex = try? Regex(pattern) else { return { _ in false } }
            return stringMatcher(field) { $0.wholeMatch(of: regex) != nil }
        default:
            return { _ in false }
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
