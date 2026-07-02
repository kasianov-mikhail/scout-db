//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct QueryPlan: Equatable, Sendable, CustomStringConvertible {
    public let server: [RecordQuery.Filter]
    public let client: [UniversalStore.Filter]
    public let sort: [RecordQuery.Sort]

    public var description: String {
        let lines =
            server.map { "SERVER \($0.field) \($0.op.rawValue) \($0.value.canonical)" }
            + client.map { "CLIENT \($0.field) \($0.op) \($0.value.canonical)" }
            + sort.map { "SORT \($0.field) \($0.ascending ? "asc" : "desc")" }
        return lines.joined(separator: "\n")
    }
}

extension UniversalStore {
    public func explain(entity: String, filters: [Filter] = [], sort: [Sort] = []) async throws -> QueryPlan {
        let definition = try await registry.definition(for: entity)
        let (server, client) = try split(filters, entity: entity, using: definition)
        return QueryPlan(server: server, client: client, sort: try recordSort(sort, using: definition))
    }

    public enum Match: Equatable, Sendable {
        case equals, notEquals
        case greaterThan, greaterThanOrEquals, lessThan, lessThanOrEquals
        case `in`, notIn, beginsWith, contains, near, search
        case endsWith, like, matches
        case isNull, isNotNull

        var serverOperator: RecordQuery.Filter.Operator? {
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
    func split(_ filters: [Filter], entity: String, using definition: EntityDefinition) throws -> (server: [RecordQuery.Filter], client: [Filter]) {
        var server = [RecordQuery.Filter(field: "entity", op: .equals, value: .string(entity))]
        var client: [Filter] = []
        let fields = definition.fields(at: definition.version)

        for filter in filters {
            guard let field = fields.first(where: { $0.name == filter.field }) else {
                throw UniversalSchemaError.unknownField(filter.field)
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
                    server.append(RecordQuery.Filter(field: slot, op: .beginsWith, value: .string(String(suffix.reversed()))))
                } else {
                    client.append(filter)
                }
            case .search:
                guard field.type == .text, case .slot(_, let slot) = field.storage else {
                    throw UniversalSchemaError.invalidValue(filter.field)
                }
                server.append(RecordQuery.Filter(field: slot, op: .search, value: filter.value))
            default:
                guard let op = filter.op.serverOperator, case .slot(_, let slot) = field.storage else {
                    throw UniversalSchemaError.unknownField(filter.field)
                }
                server.append(RecordQuery.Filter(field: slot, op: op, value: filter.value, radius: filter.radius))
            }
        }
        return (server, client)
    }

    func matches(_ record: EntityRecord, _ filter: Filter) -> Bool {
        let value = record.values[filter.field]
        switch filter.op {
        case .isNull:
            return value == nil
        case .isNotNull:
            return value != nil
        case .contains:
            guard case .string(let text)? = value, case .string(let needle) = filter.value else { return false }
            return text.contains(needle)
        case .endsWith:
            guard case .string(let text)? = value, case .string(let suffix) = filter.value else { return false }
            return text.hasSuffix(suffix)
        case .like:
            guard case .string(let text)? = value, case .string(let pattern) = filter.value else { return false }
            return Self.wildcard(pattern, matches: text)
        case .matches:
            guard case .string(let text)? = value, case .string(let pattern) = filter.value else { return false }
            guard let regex = try? Regex(pattern) else { return false }
            return text.wholeMatch(of: regex) != nil
        default:
            return false
        }
    }

    static func wildcard(_ pattern: String, matches text: String) -> Bool {
        let escaped = pattern.map { character -> String in
            switch character {
            case "*": ".*"
            case "?": "."
            default: NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
        guard let regex = try? Regex(escaped) else { return false }
        return text.wholeMatch(of: regex) != nil
    }

    private func reversedShadow(of field: FieldDefinition, in fields: [FieldDefinition]) -> FieldDefinition? {
        fields.first { $0.derived == Derivation(source: field.name, transform: .reversed) }
    }

    // The pg_trgm technique: an `ngrams` shadow slot lets the server narrow substring and
    // wildcard scans to records containing every trigram of the needle. The trigram match
    // is necessary but not sufficient, so the exact client-side matcher still runs after.
    private func ngramPrefilter(for needles: [String], of field: FieldDefinition, in fields: [FieldDefinition]) -> [RecordQuery.Filter] {
        let shadow = fields.first { $0.derived == Derivation(source: field.name, transform: .ngrams) }
        guard case .slot(_, let slot)? = shadow?.storage else { return [] }

        return needles.flatMap { needle in
            let folded = needle.folded
            guard folded.count >= 3 else { return [RecordQuery.Filter]() }
            return UniversalCoder.trigrams(of: folded).map {
                RecordQuery.Filter(field: slot, op: .contains, value: .string($0))
            }
        }
    }
}
