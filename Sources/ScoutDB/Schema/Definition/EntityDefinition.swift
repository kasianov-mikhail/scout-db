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
    var aggregates: [AggregateDefinition]?
    private let index = FieldIndex()

    private enum CodingKeys: String, CodingKey {
        case entity, version, fields, unique
        case aggregates = "views"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entity == rhs.entity
            && lhs.version == rhs.version
            && lhs.fields == rhs.fields
            && lhs.unique == rhs.unique
            && lhs.aggregates == rhs.aggregates
    }
}

extension EntityDefinition {
    func fields(at version: Int) -> [FieldDefinition] {
        index.entry(at: version, of: fields).active
    }

    func field(named name: String, at version: Int) -> FieldDefinition? {
        index.entry(at: version, of: fields).byName[name]
    }

    func fieldsByName(at version: Int) -> [String: FieldDefinition] {
        index.entry(at: version, of: fields).byName
    }
}

extension EntityDefinition {
    func aggregate(named name: String) -> AggregateDefinition? {
        aggregates?.first {
            $0.name == name
        }
    }

    func aggregate(grouping group: String?, folding field: String?) -> AggregateDefinition? {
        aggregates?.first { aggregate in
            guard aggregate.groupBy == group else {
                return false
            }
            guard let field else {
                return true
            }
            return aggregate.metricField == field
        }
    }
}
