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

    func validateReferences(of records: [EntityRecord], using definition: EntityDefinition) async throws {
        var probes: [(field: String, parent: String, keys: Set<String>)] = []
        for field in definition.fields(at: definition.version) {
            guard let parent = field.references else { continue }
            let keys = Set(records.flatMap { Self.referencedKeys($0.values[field.name]) })
            guard keys.count > 0 else { continue }
            probes.append((field.name, parent, keys))
        }
        guard probes.count > 0 else { return }

        let alive = try await withThrowingTaskGroup(of: (Int, Set<String>).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask { (index, Set(try await self.fetch(entity: probe.parent, uuids: probe.keys.sorted()).map(\.uuid))) }
            }
            var collected: [Int: Set<String>] = [:]
            for try await (index, uuids) in group {
                collected[index] = uuids
            }
            return collected
        }
        for (index, probe) in probes.enumerated() {
            if let missing = probe.keys.subtracting(alive[index] ?? []).sorted().first {
                throw SchemaError.brokenReference(field: probe.field, key: missing)
            }
        }
    }

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
        try await registry.preload()
        try await cascadeDelete(entity: entity, uuids: [uuid])
    }

    private func cascadeDelete(entity: String, uuids: [String]) async throws {
        var referring: [(child: EntityDefinition, fields: [FieldDefinition])] = []
        var detaching: [(entity: String, field: String)] = []
        for child in await registry.definitions() {
            var fields: [FieldDefinition] = []
            for field in child.fields(at: child.version) where field.references == entity {
                if field.type.isList {
                    detaching.append((child.entity, field.name))
                } else {
                    fields.append(field)
                }
            }
            if fields.count > 0 {
                referring.append((child, fields))
            }
        }
        guard referring.count + detaching.count > 0 else { return }

        let probed = try await withThrowingTaskGroup(of: (Int, [EntityRecord]).self) { group in
            for (index, target) in referring.enumerated() {
                group.addTask { (index, try await victims(of: target.child, through: target.fields, referencing: uuids)) }
            }
            var collected: [Int: [EntityRecord]] = [:]
            for try await (index, records) in group {
                collected[index] = records
            }
            return collected
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in detaching {
                group.addTask { try await detach(entity: target.entity, field: target.field, uuids: uuids) }
            }
            try await group.waitForAll()
        }
        for (index, target) in referring.enumerated() {
            guard let victims = probed[index], victims.count > 0 else { continue }
            try await tombstone(victims, using: target.child)
        }
    }

    private func victims(of child: EntityDefinition, through fields: [FieldDefinition], referencing uuids: [String]) async throws -> [EntityRecord] {
        let branches = fields.flatMap { field in
            uuids.chunked(into: 100).map { [Filter(field: field.name, op: .in, value: .strings($0))] }
        }
        return try await read(entity: child.entity, any: branches).sorted { $0.uuid < $1.uuid }
    }

    private func tombstone(_ victims: [EntityRecord], using child: EntityDefinition) async throws {
        let tombstones = try victims.map { try tombstone(entity: child.entity, uuid: $0.uuid, definition: child, values: $0.values) }
        try await database.write(records: tombstones)
        try await settle(removed: victims, using: child, auditing: false)
        noteChange(entity: child.entity, changed: victims.map { EntityStore.tombstoned($0) })
        try await cascadeDelete(entity: child.entity, uuids: victims.map(\.uuid))
    }

    private func detach(entity: String, field: String, uuids: [String]) async throws {
        let dead = Set(uuids)
        try await updateAll(entity: entity, any: Filter.containsAny(field, uuids)) { record in
            guard case .strings(let keys)? = record.values[field] else { return }
            record.values[field] = .strings(keys.filter { !dead.contains($0) })
        }
    }
}
