//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    public func join(entity: String, records: [EntityRecord], field: String) async throws -> [String: EntityRecord] {
        let definition = try await registry.definition(for: entity)
        guard let parent = definition.field(named: field, at: definition.version)?.references else {
            throw SchemaError.unknownField(field)
        }
        let keys = Set(
            records.compactMap { record -> String? in
                guard case .string(let key)? = record.values[field] else { return nil }
                return key
            })
        let parents = try await fetch(entity: parent, uuids: keys.sorted())
        return Dictionary(uniqueKeysWithValues: parents.map { ($0.uuid, $0) })
    }

    public func orphans(entity: String, field: String) async throws -> [EntityRecord] {
        let records = try await read(entity: entity)
        let parents = try await join(entity: entity, records: records, field: field)
        return records.filter { record in
            guard case .string(let key)? = record.values[field] else { return false }
            return parents[key] == nil
        }
    }

    public func delete(entity: String, uuid: String, cascade: Bool) async throws {
        try await delete(entity: entity, uuid: uuid)
        guard cascade else { return }
        try await cascadeDelete(entity: entity, uuids: [uuid])
    }

    // Tombstones every record referencing the deleted parents, level by level: each
    // referencing entity costs one chunked read, one batched tombstone write, and one
    // aggregate pass — not a per-record delete.
    private func cascadeDelete(entity: String, uuids: [String]) async throws {
        for child in await registry.definitions() {
            for field in child.fields(at: child.version) where field.references == entity {
                var victims: [EntityRecord] = []
                for chunk in uuids.chunked(into: 100) {
                    victims += try await read(entity: child.entity, filters: [Filter(field: field.name, op: .in, value: .strings(chunk))])
                }
                guard victims.count > 0 else { continue }
                let tombstones = try victims.map { try Self.tombstone(entity: child.entity, uuid: $0.uuid, definition: child) }
                try await database.write(records: tombstones)
                try await GridAggregator(database: database).remove(victims, using: child)
                try await cascadeDelete(entity: child.entity, uuids: victims.map(\.uuid))
            }
        }
    }
}
