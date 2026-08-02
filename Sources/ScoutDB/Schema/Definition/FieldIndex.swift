//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

final class FieldIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [Int: [FieldDefinition]] = [:]
    private var byName: [Int: [String: FieldDefinition]] = [:]

    func fields(at version: Int, of fields: [FieldDefinition]) -> [FieldDefinition] {
        lock.lock()
        defer {
            lock.unlock()
        }

        return activeFields(at: version, of: fields)
    }

    func fieldsByName(at version: Int, of fields: [FieldDefinition]) -> [String: FieldDefinition] {
        lock.lock()
        defer {
            lock.unlock()
        }

        if let cached = byName[version] {
            return cached
        }

        let named = Dictionary(
            activeFields(at: version, of: fields).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        byName[version] = named

        return named
    }

    private func activeFields(at version: Int, of fields: [FieldDefinition]) -> [FieldDefinition] {
        if let cached = active[version] {
            return cached
        }

        let filtered = fields.filter {
            $0.isActive(at: version)
        }
        active[version] = filtered

        return filtered
    }
}
