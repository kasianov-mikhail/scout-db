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

    func write(wanted: [VectorIndex: IndexPage]) async throws {
        var pending = wanted

        for _ in 0..<maxRetry where !pending.isEmpty {
            try await merge(pending: &pending)
        }

        guard pending.isEmpty else {
            throw VectorIndexError.contended
        }
    }

    private func merge(pending: inout [VectorIndex: IndexPage]) async throws {
        let ids = pending.keys.map(\.recordID)
        let fetched = try await database.fetchRecords(ids: ids, batchSize: maxBatchSize)
        let stored = Dictionary(uniqueKeysWithValues: fetched.map { ($0.recordID, $0) })

        let changes = try pending.compactMap { index, additions in
            try IndexChange(
                index: index,
                additions: additions, stored: stored[index.recordID])
        }

        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.record.recordID, $0) })
        pending = [:]

        for chunk in changes.chunked(size: maxBatchSize) {
            for (id, result) in try await database.saveIfUnchanged(chunk.map(\.record)) {
                guard case .failure(let error) = result else {
                    continue
                }
                guard RecordConflictError(error: error) != nil, let change = byID[id] else {
                    throw error
                }
                pending[change.index] = change.additions
            }
        }
    }
}

private struct IndexChange {
    let index: VectorIndex
    let additions: IndexPage
    let record: CKRecord

    init?(index: VectorIndex, additions: IndexPage, stored: CKRecord?) throws {
        let record = stored ?? CKRecord(index: index)
        let page = try stored?.indexPage(id: index.recordID) ?? IndexPage(weeks: [], groups: [])
        let merged = page.merging(other: additions)

        guard stored == nil || merged != page else {
            return nil
        }
        record.indexPage = merged

        self.index = index
        self.additions = additions
        self.record = record
    }
}

extension CKRecord {
    fileprivate convenience init(index: VectorIndex) {
        self.init(recordType: SchemaDescriptorEntry.recordType, recordID: index.recordID)
        self[Envelope.entity] = VectorIndex.namespace
        self[Envelope.uuid] = index.recordID.recordName
        self[Envelope.version] = Int64(1)
    }
}

extension IndexPage {
    fileprivate func merging(other: Self) -> Self {
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
