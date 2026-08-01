//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct EntityWriter: Sendable {
    let database: any CloudDatabase
    let aggregator: GridAggregator
    let entity: String
    let definition: EntityDefinition
    let coder = EntityCoder()

    func write(_ batch: [EntityWrite]) async throws -> [String] {
        var stored: Set<String> = []
        let records = try batch.map { entry in
            let resolved = try coder.resolve(
                entry.values,
                at: definition.version,
                using: definition
            )
            let natural = try coder.naturalUUID(
                for: resolved,
                using: definition
            )
            let assigned = natural ?? entry.uuid
            let uuid = assigned ?? UUID().uuidString

            if let assigned {
                stored.insert(assigned)
            }

            return EntityRecord(
                entity: entity,
                uuid: uuid,
                schemaVersion: definition.version,
                values: resolved
            )
        }

        let (removedFromViews, addedToViews) = try await rebalance(records, stored: stored)

        let encoded = try records.map {
            try coder.encode($0, using: definition)
        }

        try await database.write(records: encoded)

        try await aggregator.rebalance(
            removing: removedFromViews,
            adding: addedToViews,
            using: definition
        )

        return records.map(\.uuid)
    }

    private func rebalance(_ records: [EntityRecord], stored: Set<String>) async throws -> (
        removing: [EntityRecord], adding: [EntityRecord]
    ) {
        guard definition.views?.isEmpty == false else {
            return ([], [])
        }

        var latest: [String: EntityRecord] = [:]
        for record in records {
            latest[record.uuid] = record
        }

        let ids = latest.keys.filter(stored.contains).map { CKRecord.ID(recordName: $0) }
        let live = try await database.fetchRecords(ids: ids, batchSize: 100)
            .filter { $0["entity"] as? String == definition.entity }
            .map {
                try coder.decode($0, using: definition)
            }

        let liveByUUID = Dictionary(
            live.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return (Array(liveByUUID.values), Array(latest.values))
    }
}
