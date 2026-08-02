//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct EntityDefinition: Codable, Equatable, Sendable {
    let entity: String
    let version: Int
    let fields: [FieldDefinition]
    var unique: [String]?
    var views: [AggregateView]?
    private let index = FieldIndex()

    private enum CodingKeys: String, CodingKey {
        case entity, version, fields, unique, views
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entity == rhs.entity
            && lhs.version == rhs.version
            && lhs.fields == rhs.fields
            && lhs.unique == rhs.unique
            && lhs.views == rhs.views
    }

    func fields(at version: Int) -> [FieldDefinition] {
        index.entry(at: version, of: fields).active
    }

    func field(named name: String, at version: Int) -> FieldDefinition? {
        index.entry(at: version, of: fields).byName[name]
    }

    func fieldsByName(at version: Int) -> [String: FieldDefinition] {
        index.entry(at: version, of: fields).byName
    }

    func view(named name: String) -> AggregateView? {
        views?.first { $0.name == name }
    }

    func view(grouping group: String?, folding field: String?) -> AggregateView? {
        (views ?? []).first { view in
            guard view.groupBy == group else {
                return false
            }
            guard let field else {
                return true
            }
            return view.metricField == field
        }
    }
}

private final class FieldIndex: @unchecked Sendable {
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
