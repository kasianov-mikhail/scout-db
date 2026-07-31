//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func distinct(entity: String, field: String, filters: [Filter] = []) async throws -> [RecordValue] {
        if let grid = try await grid(of: field, entity: entity, filters: filters) {
            return grid
        }

        var seen: Set<String> = []
        var values: [RecordValue] = []

        for record in try await read(entity: entity, filters: filters, fields: [field]) {
            guard let value = record.values[field] else {
                continue
            }
            if seen.insert(value.canonical).inserted {
                values.append(value)
            }
        }

        return values
    }

    private func grid(of field: String, entity: String, filters: [Filter]) async throws -> [RecordValue]? {
        let definition = try await registry.definition(for: entity)

        guard let target = definition.field(named: field, at: definition.version) else {
            return nil
        }
        guard target.alwaysPresent, target.encrypted != true else {
            return nil
        }
        guard let parse = target.type.canonicalParser else {
            return nil
        }
        guard let folded = try await fold(of: nil, by: field, entity: entity, filters: filters) else {
            return nil
        }

        return folded.keys.sorted().compactMap(parse)
    }
}
