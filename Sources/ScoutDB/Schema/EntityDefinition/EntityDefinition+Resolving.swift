//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    private static let patterns = PatternCache()

    func resolve(_ values: [String: RecordValue], at version: Int) throws -> [String: RecordValue] {
        let active = fields(at: version)
        var resolved = values

        for field in active where resolved[field.name] == nil {
            resolved[field.name] = field.defaultValue
        }

        for field in active {
            guard let value = resolved[field.name] else {
                if field.required == true {
                    throw SchemaError.missingField(field.name)
                }
                continue
            }

            guard field.type.matches(value) else {
                throw SchemaError.typeMismatch(field.name)
            }

            if let allowed = field.allowed, !value.strings.allSatisfy(allowed.contains) {
                throw SchemaError.invalidValue(.outsideDomain(field: field.name))
            }
            if let pattern = field.pattern, let regex = Self.patterns.regex(for: pattern) {
                if !value.strings.allSatisfy({ $0.wholeMatch(of: regex) != nil }) {
                    throw SchemaError.invalidValue(.patternMismatch(field: field.name))
                }
            }

            for scalar in value.scalars {
                if let min = field.min, scalar < min {
                    throw SchemaError.invalidValue(.belowMinimum(field: field.name, minimum: min))
                }
                if let max = field.max, scalar > max {
                    throw SchemaError.invalidValue(.aboveMaximum(field: field.name, maximum: max))
                }
            }
        }

        for name in resolved.keys {
            try field(name, at: version)
        }

        return resolved
    }
}

private final class PatternCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: Regex<AnyRegexOutput>?] = [:]

    func regex(for pattern: String) -> Regex<AnyRegexOutput>? {
        lock.withLock {
            if let known = compiled[pattern] {
                return known
            }
            let regex = try? Regex(pattern)
            compiled[pattern] = regex
            return regex
        }
    }
}
