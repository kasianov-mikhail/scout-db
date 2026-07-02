//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

@testable import ScoutDB

final class InMemoryDatabase: CloudDatabase, @unchecked Sendable {
    var records: [CKRecord] = []
    var errors: [Error] = []
    var writeErrors: [Error] = []

    func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        let matched =
            records
            .filter { $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true }
            .sorted(by: query.sortDescriptors ?? [])
            .map { project($0, keys: desiredKeys) }
        return (matched.map { ($0.recordID, .success($0)) }, nil)
    }

    func records(continuingMatchFrom cursor: CKQueryOperation.Cursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?
    ) {
        ([], nil)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        upsert(record)
        return record
    }

    func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        records.forEach(upsert)
        self.records.removeAll { recordIDs.contains($0.recordID) }
    }

    private func upsert(_ record: CKRecord) {
        records.removeAll { $0.recordType == record.recordType && $0.recordID == record.recordID }
        records.append(record)
    }

    private func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        guard let keys else { return record }
        let projected = CKRecord(recordType: record.recordType, recordID: record.recordID)
        for key in record.allKeys() where keys.contains(key) {
            projected[key] = record[key]
        }
        if let date = record.recordModificationDate {
            projected.overrideModificationDate(date)
        }
        if let creator = record.recordCreator {
            projected.overrideCreator(creator)
        }
        return projected
    }
}

extension [CKRecord] {
    fileprivate func sorted(by descriptors: [NSSortDescriptor]) -> [CKRecord] {
        guard descriptors.count > 0 else { return self }
        return sorted { lhs, rhs in
            for descriptor in descriptors {
                guard let key = descriptor.key else { continue }
                let order = PredicateEvaluator.compare(lhs[key], rhs[key])
                guard order != .orderedSame else { continue }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return false
        }
    }
}
