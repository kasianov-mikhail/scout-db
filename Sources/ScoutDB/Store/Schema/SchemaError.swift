//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public enum SchemaError: Error, Equatable {
    case unknownEntity(String)
    case unknownField(String)
    case typeMismatch(String)
    case missingField(String)
    case invalidValue(String)
    case missingKey(String)
    case notFound(String)
    case staleSchema(entity: String, version: Int)
    case invalidDefinition(String)
    case brokenReference(field: String, key: String)
    case duplicateReference(field: String, key: String)
    case leaseHeld(owner: String, until: Date)
}

extension SchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownEntity(let name): "Unknown entity '\(name)'"
        case .unknownField(let name): "Unknown field '\(name)'"
        case .typeMismatch(let name): "Type mismatch for field '\(name)'"
        case .missingField(let name): "Missing required field '\(name)'"
        case .invalidValue(let name): "Invalid value for field '\(name)'"
        case .missingKey(let name): "Missing key '\(name)'"
        case .notFound(let name): "Not found: '\(name)'"
        case .staleSchema(let entity, let version): "Stale schema for entity '\(entity)' at version \(version)"
        case .invalidDefinition(let message): "Invalid definition: \(message)"
        case .brokenReference(let field, let key): "Reference field '\(field)' names a missing record '\(key)'"
        case .duplicateReference(let field, let key): "Exclusive field '\(field)' already references '\(key)'"
        case .leaseHeld(let owner, let until): "Leased by '\(owner)' until \(until)"
        }
    }
}
