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

    /// Resolves several reference fields of one read in a single call.
    ///
    /// Each field's parents are fetched concurrently; the result is keyed by
    /// field name, then by parent uuid — one dictionary per `join(field:)` call
    /// the caller would otherwise chain.
    ///
    public func join(entity: String, records: [EntityRecord], fields: [String]) async throws -> [String: [String: EntityRecord]] {
        try await withThrowingTaskGroup(of: (String, [String: EntityRecord]).self) { group in
            for field in Set(fields) {
                group.addTask { (field, try await self.join(entity: entity, records: records, field: field)) }
            }
            var joined: [String: [String: EntityRecord]] = [:]
            for try await (field, parents) in group {
                joined[field] = parents
            }
            return joined
        }
    }

    /// Follows a chain of reference fields level by level and returns every
    /// level's parents.
    ///
    /// `path[0]` resolves on the given records, `path[1]` on those parents, and
    /// so on — one dictionary (uuid → record) per hop, in path order. The last
    /// dictionary holds the far end of the chain ("the books' authors' agency").
    ///
    public func join(entity: String, records: [EntityRecord], path: [String]) async throws -> [[String: EntityRecord]] {
        var levels: [[String: EntityRecord]] = []
        var hopEntity = entity
        var hopRecords = records
        for field in path {
            let definition = try await registry.definition(for: hopEntity)
            guard let parent = definition.field(named: field, at: definition.version)?.references else {
                throw SchemaError.unknownField(field)
            }
            let parents = try await join(entity: hopEntity, records: hopRecords, field: field)
            levels.append(parents)
            hopEntity = parent
            hopRecords = Array(parents.values)
        }
        return levels
    }

    /// Reads every record of `entity` whose reference `field` names the parent.
    ///
    /// The reverse of `join`: a scalar reference matches by equality, a list
    /// reference by membership.
    ///
    public func children(entity: String, of parent: String, via field: String) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        guard let reference = definition.field(named: field, at: definition.version), reference.references != nil else {
            throw SchemaError.unknownField(field)
        }
        return try await read(entity: entity, filters: [Filter(field: field, op: reference.type.isList ? .contains : .equals, value: .string(parent))])
    }

    public func orphans(entity: String, field: String) async throws -> [EntityRecord] {
        let records = try await read(entity: entity)
        let parents = try await join(entity: entity, records: records, field: field)
        return records.filter { record in
            Self.referencedKeys(record.values[field]).contains { parents[$0] == nil }
        }
    }

    // Verifies every reference key of the batch names a live parent record; the
    // integrity gate behind the store's `enforceReferences` flag. Best-effort: a
    // parent deleted between this check and the save still slips through.
    func validateReferences(of records: [EntityRecord], using definition: EntityDefinition) async throws {
        for field in definition.fields(at: definition.version) {
            guard let parent = field.references else { continue }
            let keys = Set(records.flatMap { Self.referencedKeys($0.values[field.name]) })
            guard keys.count > 0 else { continue }
            let alive = Set(try await fetch(entity: parent, uuids: keys.sorted()).map(\.uuid))
            if let missing = keys.subtracting(alive).sorted().first {
                throw SchemaError.brokenReference(field: field.name, key: missing)
            }
        }
    }

    // Enforces one-to-one references: an exclusive field's key may be held by at
    // most one live record, so a second suitor is rejected — within the batch and
    // against the store alike. Best-effort like the integrity gate: two racing
    // writers can still both win.
    func validateExclusivity(of records: [EntityRecord], entity: String, using definition: EntityDefinition) async throws {
        for field in definition.fields(at: definition.version) where field.exclusive == true {
            var owners: [String: String] = [:]
            for record in records {
                guard case .string(let key)? = record.values[field.name] else { continue }
                if let owner = owners[key], owner != record.uuid {
                    throw SchemaError.duplicateReference(field: field.name, key: key)
                }
                owners[key] = record.uuid
            }
            guard owners.count > 0 else { continue }
            // One membership read per chunk of claimed keys rather than one read
            // per key. A rejection names the lowest colliding key, so the batch
            // fails the same way whatever order the holders come back in.
            var collisions: [String] = []
            for chunk in owners.keys.sorted().chunked(into: 100) {
                let holders = try await read(entity: entity, filters: [Filter(field: field.name, op: .in, value: .strings(chunk))])
                for holder in holders {
                    guard case .string(let key)? = holder.values[field.name], let owner = owners[key], owner != holder.uuid else { continue }
                    collisions.append(key)
                }
            }
            if let key = collisions.min() {
                throw SchemaError.duplicateReference(field: field.name, key: key)
            }
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
                let tombstones = try victims.map { try tombstone(entity: child.entity, uuid: $0.uuid, definition: child, values: $0.values) }
                try await database.write(records: tombstones)
                try await GridAggregator(database: database).remove(victims, using: child)
                noteChange(entity: child.entity)
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
