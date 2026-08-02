//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

final class FieldIndex: @unchecked Sendable {
    struct Entry {
        let active: [FieldDefinition]
        let byName: [String: FieldDefinition]
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func entry(at version: Int, of fields: [FieldDefinition]) -> Entry {
        lock.lock()
        defer {
            lock.unlock()
        }

        if let cached = entries[version] {
            return cached
        }

        let active = fields.filter {
            $0.isActive(at: version)
        }

        let entry = Entry(
            active: active,
            byName: Dictionary(active.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        )
        entries[version] = entry

        return entry
    }
}
