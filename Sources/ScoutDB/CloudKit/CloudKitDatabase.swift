//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CKDatabase: RecordReader {
    public func read(matching query: RecordQuery, fields: [String]?) async throws -> RecordChunk {
        try await read(matching: query, fields: fields, limit: CKQueryOperation.maximumResults)
    }

    public func read(matching query: RecordQuery, fields: [String]?, limit: Int) async throws -> RecordChunk {
        let results = try await records(matching: CKQuery(query), desiredKeys: fields, resultsLimit: limit)
        return try chunk(from: results)
    }

    private func chunk(from results: ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)) throws -> RecordChunk {
        let records = try results.0.map { try Record(ckRecord: $0.1.get()) }
        let cursor = results.1.map { token in
            RecordCursor { fields in
                let page = try await self.records(continuingMatchFrom: token, desiredKeys: fields, resultsLimit: CKQueryOperation.maximumResults)
                return try self.chunk(from: page)
            }
        }
        return RecordChunk(records: records, cursor: cursor)
    }
}

extension CKDatabase: RecordWriter {
    public func write(record: Record) async throws {
        do {
            try await save(record.ckRecord)
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                throw error
            }
            throw RecordConflictError(serverRecord: Record(ckRecord: server))
        }
    }

    public func write(records: [Record]) async throws {
        for chunk in records.chunked(into: Self.maxBatchSize) {
            _ = try await modifyRecords(saving: chunk.map(\.ckRecord), deleting: [], savePolicy: .allKeys, atomically: true)
        }
    }
}
