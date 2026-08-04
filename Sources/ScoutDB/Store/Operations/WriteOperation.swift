//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct WriteOperation: Sendable {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let aggregator: GridAggregator

    func save(_ batch: [EntityWrite]) async throws -> [String] {
        var stored: Set<String> = []

        let records = try batch.map { entry in
            let resolved = try definition.resolve(entry.values, at: definition.version)

            if let assigned = entry.uuid {
                stored.insert(assigned)
            }

            return EntityRecord(
                entity: definition.entity,
                uuid: entry.uuid ?? UUID().uuidString,
                schemaVersion: definition.version,
                values: resolved
            )
        }

        let (removedFromViews, addedToViews) = try await rebalance(records, stored: stored)

        let encoder = EntityEncoder(definition: definition)
        let encoded = try records.map { try encoder.encode($0) }

        for chunk in encoded.chunked(into: maxBatchSize) {
            try await database.modifyRecords(saving: chunk, deleting: [])
        }

        try await aggregator.rebalance(removing: removedFromViews, adding: addedToViews)

        return records.map(\.uuid)
    }

    private func rebalance(_ records: [EntityRecord], stored: Set<String>) async throws -> (
        removing: [EntityRecord], adding: [EntityRecord]
    ) {
        guard !definition.aggregates.isEmpty else {
            return ([], [])
        }

        var latest: [String: EntityRecord] = [:]
        for record in records {
            latest[record.uuid] = record
        }

        let ids = latest.keys.filter(stored.contains).map {
            CKRecord.ID(recordName: $0)
        }

        let decoder = EntityDecoder(definition: definition)
        let live = try await database.fetchRecords(ids: ids, batchSize: 100)
            .filter { $0["entity"] as? String == definition.entity }
            .map(decoder.decode)

        let liveByUUID = Dictionary(
            live.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return (Array(liveByUUID.values), Array(latest.values))
    }
}

extension EntityStore {
    func write(entity: String) async throws -> WriteOperation {
        let definition = try await registry.definition(for: entity)

        return WriteOperation(
            database: database,
            definition: definition,
            aggregator: GridAggregator(database: database, aggregates: definition.aggregates, slots: slots)
        )
    }
}
