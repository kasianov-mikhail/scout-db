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
    let aggregator: VectorAggregator

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
        .upserts

        let replaced = try await previous(records, stored: stored)

        let encoder = EntityEncoder(definition: definition)
        let encoded = try records.map(encoder.encode)

        for chunk in encoded.chunked(into: maxBatchSize) {
            try await database.modifyRecords(saving: chunk, deleting: [])
        }

        try await aggregator.rebalance(removing: replaced, adding: records)

        return records.map(\.uuid)
    }

    private func previous(_ records: [EntityRecord], stored: Set<String>) async throws -> [EntityRecord] {
        guard !definition.aggregates.isEmpty else {
            return []
        }

        let ids = records.map(\.uuid).filter(stored.contains).map(CKRecord.ID.init(recordName:))

        let decoder = EntityDecoder(definition: definition)
        let live = try await database.fetchRecords(ids: ids, batchSize: 100)
            .filter { $0[Envelope.entity] as? String == definition.entity }
            .map(decoder.decode)

        let liveByUUID = Dictionary(
            live.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return Array(liveByUUID.values)
    }
}

extension [EntityRecord] {
    fileprivate var upserts: [EntityRecord] {
        var position: [String: Int] = [:]
        var records: [EntityRecord] = []

        for record in self {
            if let index = position[record.uuid] {
                records[index] = record
            } else {
                position[record.uuid] = records.count
                records.append(record)
            }
        }

        return records
    }
}

extension EntityStore {
    func write(entity: String) async throws -> WriteOperation {
        let definition = try await registry.definition(for: entity)

        return WriteOperation(
            database: database,
            definition: definition,
            aggregator: VectorAggregator(database: database, aggregates: definition.aggregates, slots: slots)
        )
    }
}
