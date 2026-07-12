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
        let keys = Set(records.flatMap { Self.referencedKeys($0.values[field]) })
        let parents = try await fetch(entity: parent, uuids: keys.sorted())
        return Dictionary(uniqueKeysWithValues: parents.map { ($0.uuid, $0) })
    }

    public func orphans(entity: String, field: String) async throws -> [EntityRecord] {
        let records = try await read(entity: entity)
        let parents = try await join(entity: entity, records: records, field: field)
        return records.filter { record in
            Self.referencedKeys(record.values[field]).contains { parents[$0] == nil }
        }
    }

    // A scalar reference names one parent, a list reference names many — the
    // many-to-many shape, where several records share several parents.
    private static func referencedKeys(_ value: RecordValue?) -> [String] {
        switch value {
        case .string(let key): [key]
        case .strings(let keys): keys
        default: []
        }
    }

    public func delete(entity: String, uuid: String, cascade: Bool) async throws {
        try await delete(entity: entity, uuid: uuid)
        guard cascade else { return }
        // The cascade walks the registry's definitions, so every published entity
        // must be in the cache first — an entity never read in this session would
        // otherwise silently keep its referencing records.
        try await registry.preload()
        try await cascadeDelete(entity: entity, uuids: [uuid])
    }

    // Tombstones every record referencing the deleted parents, level by level: each
    // referencing entity costs one chunked read, one batched tombstone write, and one
    // aggregate pass — not a per-record delete. A list reference is a many-to-many
    // link, so its records are detached instead of deleted and the cascade stops there.
    private func cascadeDelete(entity: String, uuids: [String]) async throws {
        for child in await registry.definitions() {
            for field in child.fields(at: child.version) where field.references == entity {
                guard !field.type.isList else {
                    try await detach(entity: child.entity, field: field.name, uuids: uuids)
                    continue
                }
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

    // Strips the deleted parents' keys out of every list reference naming them. One
    // filtered rewrite per deleted parent, but each rewrite drops every dead key it
    // touches, so later passes only match records the earlier ones missed.
    private func detach(entity: String, field: String, uuids: [String]) async throws {
        let dead = Set(uuids)
        for uuid in uuids {
            try await updateAll(entity: entity, filters: [Filter(field: field, op: .contains, value: .string(uuid))]) { record in
                guard case .strings(let keys)? = record.values[field] else { return }
                record.values[field] = .strings(keys.filter { !dead.contains($0) })
            }
        }
    }
}
