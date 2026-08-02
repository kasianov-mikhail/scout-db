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
    let aggregator: GridAggregator
    let entity: String
    let definition: EntityDefinition
    let encoder: EntityEncoder
    let decoder: EntityDecoder

    init(database: any CloudDatabase, aggregator: GridAggregator, entity: String, definition: EntityDefinition) {
        self.database = database
        self.aggregator = aggregator
        self.entity = entity
        self.definition = definition
        self.encoder = EntityEncoder(definition: definition)
        self.decoder = EntityDecoder(definition: definition)
    }

    func write(_ batch: [EntityWrite]) async throws -> [String] {
        var stored: Set<String> = []
        let records = try batch.map { entry in
            let resolved = try definition.resolve(entry.values, at: definition.version)
            let natural = try naturalUUID(for: resolved)
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

        let encoded = try records.map(encoder.encode)

        for chunk in encoded.chunked(into: maxBatchSize) {
            try await database.modifyRecords(saving: chunk, deleting: [])
        }

        try await aggregator.rebalance(
            removing: removedFromViews,
            adding: addedToViews,
            using: definition
        )

        return records.map(\.uuid)
    }

    private func naturalUUID(for values: [String: RecordValue]) throws -> String? {
        guard let unique = definition.unique else {
            return nil
        }
        let key = try unique.map { name in
            guard let value = values[name] else {
                throw SchemaError.missingField(name)
            }
            return "\(name)=\(value.canonical)"
        }
        return contentDigest(of: key)
    }

    private func rebalance(_ records: [EntityRecord], stored: Set<String>) async throws -> (
        removing: [EntityRecord], adding: [EntityRecord]
    ) {
        guard definition.aggregates?.isEmpty == false else {
            return ([], [])
        }

        var latest: [String: EntityRecord] = [:]
        for record in records {
            latest[record.uuid] = record
        }

        let ids = latest.keys.filter(stored.contains).map { CKRecord.ID(recordName: $0) }
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
