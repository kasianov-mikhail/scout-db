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
    case invalidValue(ValueFault)
    case staleSchema(entity: String, version: Int)
    case invalidDefinition(DefinitionFault)
    case unsupportedQuery(QueryFault)
    case malformedRecord(String)
}

extension SchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownEntity(let name):
            "Unknown entity '\(name)'"
        case .unknownField(let name):
            "Unknown field '\(name)'"
        case .typeMismatch(let name):
            "Type mismatch for field '\(name)'"
        case .missingField(let name):
            "Missing required field '\(name)'"
        case .invalidValue(let fault):
            "Invalid value: \(fault)"
        case .staleSchema(let entity, let version):
            "Stale schema for entity '\(entity)' at version \(version)"
        case .invalidDefinition(let fault):
            "Invalid definition: \(fault)"
        case .unsupportedQuery(let fault):
            "Unsupported query: \(fault)"
        case .malformedRecord(let name):
            "Malformed record '\(name)'"
        }
    }
}
