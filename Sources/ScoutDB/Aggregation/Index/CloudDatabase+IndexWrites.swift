//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

private let maxIndexRetry = 3

extension CloudDatabase {
    func write(wanted: [VectorIndex: IndexPage]) async throws {
        let fetched = try await fetchRecords(
            ids: wanted.keys.map(\.recordID),
            batchSize: maxBatchSize
        )

        var stored = Dictionary(uniqueKeysWithValues: fetched.map { ($0.recordID, $0) })
        var pending = wanted

        for _ in 0..<maxIndexRetry where !pending.isEmpty {
            let indexes = Dictionary(uniqueKeysWithValues: pending.keys.map { ($0.recordID, $0) })
            let changes = try pending.compactMap { index, additions in
                try index.record(adding: additions, stored: stored[index.recordID])
            }
            var retry: [VectorIndex: IndexPage] = [:]

            for chunk in changes.chunked(size: maxBatchSize) {
                for (id, result) in try await saveIfUnchanged(chunk) {
                    guard case .failure(let error) = result else {
                        continue
                    }
                    guard let conflict = RecordConflictError(error: error), let index = indexes[id] else {
                        throw error
                    }
                    stored[id] = conflict.serverRecord
                    retry[index] = pending[index]
                }
            }

            pending = retry
        }

        guard pending.isEmpty else {
            throw VectorIndexError.contended
        }
    }
}

extension VectorIndex {
    fileprivate func record(adding additions: IndexPage, stored: CKRecord?) throws -> CKRecord? {
        let record = stored ?? CKRecord(index: self)
        let page = try stored?.indexPage(id: recordID) ?? IndexPage(weeks: [], groups: [])
        let merged = page.merging(other: additions)

        guard stored == nil || merged != page else {
            return nil
        }
        record.indexPage = merged
        return record
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

enum VectorIndexError: Error {
    case contended
}
