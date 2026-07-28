//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    @discardableResult public func increment(entity: String, uuid: String, field: String, by delta: Double = 1) async throws -> Double {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else {
            throw SchemaError.unknownField(field)
        }

        var result = 0.0
        switch target.type {
        case .int:
            guard delta == delta.rounded() else {
                throw SchemaError.invalidValue(field)
            }
            try await update(entity: entity, uuid: uuid) { record in
                var current: Int64 = 0
                if case .int(let value)? = record.values[field] {
                    current = value
                }
                let next = current + Int64(delta)
                record.values[field] = .int(next)
                result = Double(next)
            }
        case .double:
            try await update(entity: entity, uuid: uuid) { record in
                var current: Double = 0
                if case .double(let value)? = record.values[field] {
                    current = value
                }
                let next = current + delta
                record.values[field] = .double(next)
                result = next
            }
        default:
            throw SchemaError.invalidValue(field)
        }
        return result
    }

    @discardableResult public func insert(_ elements: [String], into field: String, entity: String, uuid: String) async throws -> [String] {
        try await mutateList(field: field, entity: entity, uuid: uuid) { current in
            var merged = current
            for element in elements where !merged.contains(element) {
                merged.append(element)
            }
            return merged
        }
    }

    @discardableResult public func remove(_ elements: [String], from field: String, entity: String, uuid: String) async throws -> [String] {
        let dropped = Set(elements)
        return try await mutateList(field: field, entity: entity, uuid: uuid) { current in
            current.filter { !dropped.contains($0) }
        }
    }

    private func mutateList(field: String, entity: String, uuid: String, transform: @escaping ([String]) -> [String]) async throws -> [String] {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else {
            throw SchemaError.unknownField(field)
        }
        guard target.type == .stringList else {
            throw SchemaError.invalidValue(field)
        }
        var result: [String] = []
        try await update(entity: entity, uuid: uuid) { record in
            var current: [String] = []
            if case .strings(let values)? = record.values[field] {
                current = values
            }
            result = transform(current)
            record.values[field] = .strings(result)
        }
        return result
    }
}
