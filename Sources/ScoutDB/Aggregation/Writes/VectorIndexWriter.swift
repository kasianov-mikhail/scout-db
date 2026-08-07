//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorIndexWriter {
    let database: any CloudDatabase
    let maxRetry = 3

    func note(_ slots: some Collection<VectorSlot>) async throws {
        var weeks: [VectorIndex: Set<Int64>] = [:]
        var groups: [VectorIndex: Set<String>] = [:]

        for slot in slots {
            let (head, week) = slot.index
            weeks[head, default: []].insert(slot.week.millisecondsSince1970)
            groups[week, default: []].insert(slot.group)
        }

        var wanted = weeks.mapValues { IndexPage(weeks: $0.sorted(), groups: []) }
        wanted.merge(groups.mapValues { IndexPage(weeks: [], groups: $0.sorted()) }) { first, _ in first }

        try await write(wanted)
    }

    func write(_ wanted: [VectorIndex: IndexPage]) async throws {
        var pending = wanted
        for _ in 0..<maxRetry {
            pending = try await merge(pending)

            guard pending.count > 0 else {
                return
            }
        }

        throw VectorIndexError.contended
    }

    private func merge(_ wanted: [VectorIndex: IndexPage]) async throws -> [VectorIndex: IndexPage] {
        let ids = wanted.keys.map(\.recordID).sorted { $0.recordName < $1.recordName }
        var stored: [CKRecord.ID: CKRecord] = [:]

        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            stored[record.recordID] = record
        }

        var saving: [CKRecord.ID: (index: VectorIndex, page: IndexPage, record: CKRecord)] = [:]

        for (index, additions) in wanted {
            let record: CKRecord
            let page: IndexPage

            if let existing = stored[index.recordID] {
                record = existing
                page = try existing.indexPage(named: index.recordID)
            } else {
                record = CKRecord(recordType: SchemaDescriptorEntry.recordType, recordID: index.recordID)
                record[Envelope.entity] = VectorIndex.namespace
                record[Envelope.version] = Int64(1)
                page = IndexPage(weeks: [], groups: [])
            }

            let merged = page.merging(additions)

            guard merged != page else {
                continue
            }
            record.indexPage = merged
            saving[index.recordID] = (index, additions, record)
        }

        var retry: [VectorIndex: IndexPage] = [:]

        for chunk in Array(saving.values).chunked(into: maxBatchSize) {
            for (id, result) in try await database.saveIfUnchanged(chunk.map(\.record)) {
                guard case .failure(let error) = result else {
                    continue
                }
                guard RecordConflictError(error) != nil, let entry = saving[id] else {
                    throw error
                }
                retry[entry.index] = entry.page
            }
        }

        return retry
    }
}

extension IndexPage {
    fileprivate func merging(_ other: Self) -> Self {
        Self(
            weeks: Set(weeks).union(other.weeks).sorted(),
            groups: Set(groups).union(other.groups).sorted(),
            shards: shards.merging(other.shards, uniquingKeysWith: Swift.max)
        )
    }
}

enum VectorIndexError: Error, Equatable {
    case contended
}
