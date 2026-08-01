//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension Filter {
    func matcher() -> (EntityRecord) -> Bool {
        switch op {
        case .equals:
            return { $0.values[field] == value }

        case .notEquals:
            return { $0.values[field].map { $0 != value } ?? false }

        case .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            return comparisonMatcher()

        case .in:
            let options = Set(value.members ?? [value])
            return { $0.values[field].map(options.contains) ?? false }

        case .notIn:
            let options = Set(value.members ?? [value])
            return { record in record.values[field].map { !options.contains($0) } ?? false }

        case .beginsWith:
            guard case .string(let prefix) = value else {
                return { _ in false }
            }
            return Self.stringMatcher(field) { $0.hasPrefix(prefix) }

        case .contains:
            guard case .string(let needle) = value else {
                return { _ in false }
            }
            let field = field
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
            guard case .string(let needle) = value else {
                return { _ in false }
            }
            let needles = needle.searchTokens
            return Self.stringMatcher(field) { text in
                let tokens = Set(text.searchTokens)
                return needles.allSatisfy(tokens.contains)
            }
        }
    }

    private func comparisonMatcher() -> (EntityRecord) -> Bool {
        { record in
            guard let stored = record.values[field], Self.comparable(stored, value) else {
                return false
            }
            return switch (op, RecordValue.rank(stored, value)) {
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

extension String {
    /// The lowercased alphanumeric runs a full-text search matches on.
    fileprivate var searchTokens: [Substring] {
        lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
