//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

extension EntityStore {
    @discardableResult func deleteAll(entity: String, any branches: [[Filter]], createdBy creator: String? = nil) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        var seen: Set<String> = []
        var removed = 0
        for branch in branches {
            let (query, included) = try liveQuery(branch, entity: entity, createdBy: creator, using: definition)
            try await forEachPage(matching: query, using: definition) { page in
                let victims = page.filter { included($0) && seen.insert($0.uuid).inserted }
                guard victims.count > 0 else {
                    return
                }
                try await tombstone(victims, using: definition)
                removed += victims.count
            }
        }
        return removed
    }

    func tombstone(_ removed: [EntityRecord], using definition: EntityDefinition) async throws {
        try await tombstone(uuids: removed.map(\.uuid), removing: removed, using: definition)
    }

    func tombstone(uuids: [String], removing removed: [EntityRecord], using definition: EntityDefinition) async throws {
        let values = Dictionary(removed.map { ($0.uuid, $0.values) }, uniquingKeysWith: { first, _ in first })
        let tombstones = try uuids.map {
            try tombstone(entity: definition.entity, uuid: $0, definition: definition, values: values[$0] ?? [:])
        }
        try await database.write(records: tombstones)
        try await settle(removed: removed, using: definition)
    }

    func settle(removed: [EntityRecord], using definition: EntityDefinition) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await releaseUniqueClaims(of: removed, using: definition) }
            group.addTask { try await aggregator.remove(removed, using: definition) }
            try await group.waitForAll()
        }
    }
}
