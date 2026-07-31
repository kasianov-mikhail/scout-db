//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

private struct RecordBatch: @unchecked Sendable {
    let index: Int
    let records: [CKRecord]
}

extension CloudDatabase {
    /// Fetches the IDs one at a time; a conformance that can fetch a batch in
    /// one request overrides this.
    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        for id in ids {
            if let record = try await fetchRecord(id: id) {
                records.append(record)
            }
        }
        return records
    }

    func fetchRecords(ids: [CKRecord.ID], batchSize: Int) async throws -> [CKRecord] {
        guard ids.count > 0 else {
            return []
        }
        guard ids.count > batchSize else {
            return try await fetchRecords(ids: ids)
        }
        let database = self

        return try await withThrowingTaskGroup(of: RecordBatch.self) { group in
            for (index, batch) in ids.chunked(into: batchSize).enumerated() {
                group.addTask {
                    RecordBatch(
                        index: index,
                        records: try await database.fetchRecords(ids: batch)
                    )
                }
            }

            var batches: [Int: [CKRecord]] = [:]
            for try await batch in group {
                batches[batch.index] = batch.records
            }
            return batches.sorted { $0.key < $1.key }.flatMap(\.value)
        }
    }
}
