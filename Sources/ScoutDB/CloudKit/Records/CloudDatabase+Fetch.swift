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

    func fetchRecords(ids: [CKRecord.ID], batchSize: Int) async throws -> [CKRecord] {
        guard !ids.isEmpty else { return [] }
        guard ids.count > batchSize else {
            return try await fetchRecords(ids: ids)
        }
        let sorted = ids.sorted { $0.recordName < $1.recordName }
        return try await sorted.chunked(size: batchSize).orderedBatches(body: fetchRecords(ids:))
    }
}
