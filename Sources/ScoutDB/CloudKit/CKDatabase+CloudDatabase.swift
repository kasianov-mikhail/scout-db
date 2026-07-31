//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CKDatabase: CloudDatabase {
    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> QueryPage {
        do {
            return try await throttled { database in
                let (results, cursor) = try await database.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: desiredKeys,
                    resultsLimit: resultsLimit
                )
                return (results, cursor.map(QueryCursor.cloudKit))
            }
        } catch let error as CKError where error.code == .unknownItem {
            return ([], nil)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> QueryPage {
        guard case .cloudKit(let cursor) = cursor else {
            throw CKError(.invalidArguments)
        }
        return try await throttled { database in
            let (results, next): (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?) =
                try await withCheckedThrowingContinuation { continuation in
                    database.fetch(
                        withCursor: cursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: resultsLimit
                    ) { result in
                        continuation.resume(with: result)
                    }
                }
            return (results, next.map(QueryCursor.cloudKit))
        }
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        try await throttled { database in
            do {
                let results = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )

                guard let result = results.saveResults[record.recordID] else {
                    throw CKError(.internalError)
                }
                return try result.get()
            } catch let error as CKError where error.code == .partialFailure {
                guard let perItem = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error] else {
                    throw error
                }
                guard let cause = perItem[record.recordID] else {
                    throw error
                }
                throw cause
            }
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await throttled { database in
            _ = try await database.modifyRecords(
                saving: records,
                deleting: recordIDs,
                savePolicy: .allKeys,
                atomically: true
            )
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await throttled { database in
            let results = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )

            return records.map { record in
                guard let result = results.saveResults[record.recordID] else {
                    return (record.recordID, .failure(CKError(.internalError)))
                }
                guard case .failure(let error) = result, let conflict = RecordConflictError(error) else {
                    return (record.recordID, result)
                }
                return (record.recordID, .failure(conflict))
            }
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await throttled { database in
            do {
                return try await database.records(for: [id])[id]?.get()
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        guard ids.count > 0 else {
            return []
        }

        return try await throttled { database in
            let results = try await database.records(for: ids)

            return try ids.compactMap { id in
                guard let result = results[id] else {
                    return nil
                }
                do {
                    return try result.get()
                } catch let error as CKError where error.code == .unknownItem {
                    return nil
                }
            }
        }
    }
}
