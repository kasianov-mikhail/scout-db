//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

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
                let tombstones = try victims.map { try tombstone(entity: entity, uuid: $0.uuid, definition: definition, values: $0.values) }
                try await database.write(records: tombstones)
                try await settle(removed: victims, using: definition)
                removed += victims.count
            }
        }
        return removed
    }

    func purge(entity: String, filters: [Filter]) async throws -> Int {
        let victims = try await read(entity: entity, filters: filters, fields: [])
        let ids = victims.map { CKRecord.ID(recordName: $0.uuid) }
        try await database.delete(records: ids)
        return ids.count
    }

    func settle(removed: [EntityRecord], using definition: EntityDefinition, auditing: Bool = true) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await releaseUniqueClaims(of: removed, using: definition) }
            group.addTask { try await aggregator.remove(removed, using: definition) }
            if auditing {
                group.addTask { try await recordRevisions(removed, using: definition) }
            }
            try await group.waitForAll()
        }
    }
}
