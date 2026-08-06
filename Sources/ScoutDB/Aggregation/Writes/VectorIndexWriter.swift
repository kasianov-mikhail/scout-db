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
        guard slots.count > 0 else {
            return
        }

        var wanted: [VectorIndex: VectorIndex.Page] = [:]

        for slot in slots {
            let (head, week) = slot.index
            wanted[head, default: VectorIndex.Page()].weeks.append(slot.week.millisecondsSince1970)
            wanted[week, default: VectorIndex.Page()].groups.append(slot.group)
        }

        var pending = wanted
        for _ in 0..<maxRetry {
            pending = try await merge(pending)

            guard pending.count > 0 else {
                return
            }
        }

        throw VectorIndexError.contended
    }

    private func merge(_ wanted: [VectorIndex: VectorIndex.Page]) async throws -> [VectorIndex: VectorIndex.Page] {
        let ids = wanted.keys.map(\.recordID).sorted { $0.recordName < $1.recordName }
        var stored: [CKRecord.ID: CKRecord] = [:]

        for record in try await database.fetchRecords(ids: ids, batchSize: maxBatchSize) {
            stored[record.recordID] = record
        }

        var saving: [CKRecord.ID: (index: VectorIndex, page: VectorIndex.Page, record: CKRecord)] = [:]

        for (index, additions) in wanted {
            let record = stored[index.recordID] ?? index.blank()
            let page = try VectorIndex.page(of: record)
            let merged = page.merging(additions)

            guard merged != page else {
                continue
            }
            try VectorIndex.store(merged, in: record)
            saving[index.recordID] = (index, additions, record)
        }

        guard saving.count > 0 else {
            return [:]
        }

        var retry: [VectorIndex: VectorIndex.Page] = [:]

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

extension VectorIndex.Page {
    fileprivate func merging(_ other: Self) -> Self {
        Self(
            weeks: weeks.count > 0 || other.weeks.count > 0 ? Array(Set(weeks).union(other.weeks)).sorted() : [],
            groups: groups.count > 0 || other.groups.count > 0 ? Array(Set(groups).union(other.groups)).sorted() : []
        )
    }
}

enum VectorIndexError: Error, Equatable {
    case contended
}
