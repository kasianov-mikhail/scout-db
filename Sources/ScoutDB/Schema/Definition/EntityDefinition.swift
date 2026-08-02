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
        index.fields(at: version, of: fields)
    }

    func fieldsByName(at version: Int) -> [String: FieldDefinition] {
        index.fieldsByName(at: version, of: fields)
    }

    /// The field the entity declares under `name`, as of `version`.
    @discardableResult func field(_ name: String, at version: Int) throws -> FieldDefinition {
        guard let field = fieldsByName(at: version)[name] else {
            throw SchemaError.unknownField(name)
        }
        return field
    }

    /// The field the entity declares under `name` at its current version.
    @discardableResult func field(_ name: String) throws -> FieldDefinition {
        try field(name, at: version)
    }
}

extension EntityDefinition {
    func aggregate(named name: String) -> AggregateDefinition? {
        aggregates?.first {
            $0.name == name
        }
    }

    func aggregate(grouping group: String?, folding field: String?, as metric: Metric) -> AggregateDefinition? {
        aggregates?.first { aggregate in
            guard aggregate.groupBy == group else {
                return false
            }
            guard let field else {
                return true
            }
            return aggregate.metricKind == metric.storage && aggregate.metricField == field
        }
    }
}
