//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension UniversalStore {
    func join(entity: String, records: [EntityRecord], field: String) async throws -> [String: EntityRecord] {
        let definition = try await registry.definition(for: entity)
        guard let parent = definition.fields(at: definition.version).first(where: { $0.name == field })?.references else {
            throw UniversalSchemaError.unknownField(field)
        }
        let keys = Set(
            records.compactMap { record -> String? in
                guard case .string(let key)? = record.values[field] else { return nil }
                return key
            })
        let parents = try await fetch(entity: parent, uuids: keys.sorted())
        return Dictionary(uniqueKeysWithValues: parents.map { ($0.uuid, $0) })
    }

    func orphans(entity: String, field: String) async throws -> [EntityRecord] {
        let records = try await read(entity: entity)
        let parents = try await join(entity: entity, records: records, field: field)
        return records.filter { record in
            guard case .string(let key)? = record.values[field] else { return false }
            return parents[key] == nil
        }
    }

    func delete(entity: String, uuid: String, cascade: Bool) async throws {
        try await delete(entity: entity, uuid: uuid)
        guard cascade else { return }

        for child in await registry.definitions() {
            for field in child.fields(at: child.version) where field.references == entity {
                let filter = Filter(field: field.name, op: .equals, value: .string(uuid))
                for record in try await read(entity: child.entity, filters: [filter]) {
                    try await delete(entity: child.entity, uuid: record.uuid, cascade: true)
                }
            }
        }
    }
}
