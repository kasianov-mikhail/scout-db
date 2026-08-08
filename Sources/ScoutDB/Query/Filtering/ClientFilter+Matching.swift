//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension ClientFilter {
    func matches(_ record: EntityRecord) -> Bool? {
        let stored = record.values[field]
        let options = value.members ?? [value]

        switch op {
        case .equals:
            return stored.map { $0 == value }

        case .notEquals:
            return stored.map { $0 != value }

        case .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            return stored?.satisfies(op, against: value)

        case .in:
            return stored.map { options.contains($0) }

        case .notIn:
            return stored.map { !options.contains($0) }

        case .beginsWith:
            guard case .string(let prefix) = value, case .string(let text)? = stored else {
                return nil
            }
            return text.hasPrefix(prefix)

        case .contains:
            if let members = stored?.members {
                return members.contains(value)
            }
            guard case .string(let needle) = value, case .string(let text)? = stored else {
                return nil
            }
            return text.contains(needle)

        case .search:
            guard case .string(let needle) = value, case .string(let text)? = stored else {
                return nil
            }
            return needle.searchTokens.allSatisfy(text.searchTokens.contains)
        }
    }
}

extension String {
    fileprivate var searchTokens: [Substring] {
        lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
