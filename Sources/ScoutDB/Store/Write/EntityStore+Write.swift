//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    @discardableResult public func write(_ values: [String: RecordValue], entity: String, uuid: String? = nil)
        async throws -> String
    {
        let entry = uuid.map { EntityWrite(values: values, uuid: $0) } ?? EntityWrite(values: values)
        return try await write([entry], entity: entity)[0]
    }

    @discardableResult public func write(_ batch: [EntityWrite], entity: String) async throws -> [String] {
        guard batch.count > 0 else {
            return []
        }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder()

        var stored: Set<String> = []
        let entityRecords = try batch.map { entry in
            let resolved = try coder.resolve(entry.values, at: definition.version, using: definition)
            let natural = try coder.naturalUUID(for: resolved, using: definition)
            let uuid = natural ?? entry.uuid
            if natural != nil || entry.assigned {
                stored.insert(uuid)
            }
            return EntityRecord(entity: entity, uuid: uuid, schemaVersion: definition.version, values: resolved)
        }

        let (removedFromViews, addedToViews) = try await aggregationRebalance(
            entityRecords,
            stored: stored,
            using: definition
        )

        let encoded = try entityRecords.map { try coder.encode($0, using: definition) }
        try await database.write(records: encoded)
        try await aggregator.rebalance(removing: removedFromViews, adding: addedToViews, using: definition)
        return entityRecords.map(\.uuid)
    }

    private func aggregationRebalance(
        _ records: [EntityRecord], stored: Set<String>, using definition: EntityDefinition
    ) async throws -> (removing: [EntityRecord], adding: [EntityRecord]) {
        guard definition.views?.isEmpty == false else {
            return ([], [])
        }
        var latest: [String: EntityRecord] = [:]
        for record in records { latest[record.uuid] = record }
        let live = try decode(
            try await items(entity: definition.entity, uuids: latest.keys.filter(stored.contains)),
            using: definition
        )
        let liveByUUID = Dictionary(live.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var removing: [EntityRecord] = []
        var adding: [EntityRecord] = []
        for (uuid, record) in latest {
            if let old = liveByUUID[uuid] {
                removing.append(old)
            }
            adding.append(record)
        }
        return (removing, adding)
    }
}
