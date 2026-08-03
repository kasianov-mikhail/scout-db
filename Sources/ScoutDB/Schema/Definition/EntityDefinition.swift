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

    var activeFields: [FieldDefinition] {
        index.fields(at: version, of: fields)
    }

    @discardableResult func field(_ name: String, at version: Int) throws -> FieldDefinition {
        guard let field = index.fieldsByName(at: version, of: fields)[name] else {
            throw SchemaError.unknownField(name)
        }
        return field
    }
}
