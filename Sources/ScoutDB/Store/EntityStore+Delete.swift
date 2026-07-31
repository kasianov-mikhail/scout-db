//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    public func delete(entity: String, uuid: String) async throws {
        try await delete(entity: entity, uuids: [uuid])
    }

    func delete(entity: String, uuids: [String]) async throws {
        guard uuids.count > 0 else {
            return
        }
        var targets: [String] = []
        var seen: Set<String> = []
        for uuid in uuids where seen.insert(uuid).inserted {
            targets.append(uuid)
        }
        let definition = try await registry.definition(for: entity)
        let removed = try decode(try await items(entity: entity, uuids: targets), using: definition)
        try await remove(removed, using: definition)
    }

    @discardableResult func deleteAll(entity: String, any branches: [[Filter]]) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        var seen: Set<String> = []
        var removed = 0
        for branch in branches {
            let (query, included) = try liveQuery(branch, entity: entity, using: definition)
            try await forEachPage(matching: query, using: definition) { page in
                let victims = page.filter { included($0) && seen.insert($0.uuid).inserted }
                guard victims.count > 0 else {
                    return
                }
                try await remove(victims, using: definition)
                removed += victims.count
            }
        }
        return removed
    }

    func remove(_ removed: [EntityRecord], using definition: EntityDefinition) async throws {
        try await database.delete(records: removed.map { CKRecord.ID(recordName: $0.uuid) })
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
