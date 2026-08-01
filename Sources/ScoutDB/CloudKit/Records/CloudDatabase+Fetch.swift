//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CloudDatabase {
    /// The records for those IDs, in the order asked, with the missing ones
    /// left out.
    ///
    /// The default answer to ``CloudDatabase/fetchRecords(ids:)``: one
    /// ``CloudDatabase/fetchRecord(id:)`` awaited per ID, so n IDs cost n round
    /// trips. A conformance that can ask for a batch in a single request
    /// overrides it, and internal callers with a long list reach for
    /// ``fetchRecords(ids:batchSize:)`` instead.
    ///
    /// A missing ID is an answer rather than an error, so the result is shorter
    /// than `ids` — never holed, and never nil in a slot. Positions therefore
    /// stop lining up as soon as one record is gone: match on `recordID` rather
    /// than on index.
    ///
    /// ```swift
    /// let ids = uuids.map { CKRecord.ID(recordName: $0) }
    /// let records = try await database.fetchRecords(ids: ids)
    ///
    /// let found = Set(records.map(\.recordID))
    /// let missing = ids.filter { !found.contains($0) }
    /// ```
    ///
    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        for id in ids {
            if let record = try await fetchRecord(id: id) {
                records.append(record)
            }
        }
        return records
    }

    /// The same fetch as ``fetchRecords(ids:)``, cut into `batchSize` chunks
    /// that run at once, still answering in the order asked.
    ///
    /// Every chunk is its own task, and tasks complete in whatever order the
    /// server lets them. The result does not inherit that order: each chunk
    /// carries the position it was cut from, and the batches are sorted back
    /// before they are flattened. Order matches `ids` exactly as the serial
    /// fetch does, with missing records left out the same way.
    ///
    /// Short lists skip the machinery — an empty list answers empty, and one
    /// that fits a single chunk goes straight to ``fetchRecords(ids:)``, which
    /// a conformance may already serve in one request. So `batchSize` is worth
    /// setting to what a single request can carry rather than to a slice of the
    /// expected total.
    ///
    /// ```swift
    /// let ids = slots.map(\.recordID)
    /// let records = try await database.fetchRecords(ids: ids, batchSize: maxBatch)
    ///
    /// for record in records {
    ///     await cache.keep(record)
    /// }
    /// ```
    ///
    func fetchRecords(ids: [CKRecord.ID], batchSize: Int) async throws -> [CKRecord] {
        guard ids.count > 0 else {
            return []
        }
        guard ids.count > batchSize else {
            return try await fetchRecords(ids: ids)
        }
        let database = self

        return try await ids.chunked(into: batchSize).orderedBatches { batch in
            try await database.fetchRecords(ids: batch)
        }
    }
}
