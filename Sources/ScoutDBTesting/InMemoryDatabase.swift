//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

public final class InMemoryDatabase: CloudDatabase, @unchecked Sendable {
    public var records: [CKRecord] = []
    public var errors: [Error] = []
    public var writeErrors: [Error] = []

    /// Caps every response page the way the CloudKit server does, so tests can
    /// force multi-page reads even for requests made at
    /// `CKQueryOperation.maximumResults`. `nil` leaves only `resultsLimit` in effect.
    public var pageLimit: Int?

    public init() {}

    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        return page(query: query, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        guard case .offset(let query, let offset) = cursor else { throw CKError(.invalidArguments) }
        return page(query: query, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit)
    }

    // Re-evaluates the query and serves one page from `offset`, mirroring the
    // server: at most `resultsLimit` records per response (`maximumResults`, i.e.
    // 0, means "as many as fit under `pageLimit`") and a cursor whenever matches
    // remain beyond the page.
    private func page(query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, offset: Int, resultsLimit: Int) -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let matched =
            records
            .filter { $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true }
            .sorted(by: query.sortDescriptors ?? [])
        let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
        let page = matched.dropFirst(offset).prefix(capacity).map { project($0, keys: desiredKeys) }
        let end = offset + page.count
        let cursor: QueryCursor? = end < matched.count ? .offset(query: query, offset: end) : nil
        return (page.map { ($0.recordID, .success($0)) }, cursor)
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        upsert(record)
        return record
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        records.forEach(upsert)
        let deleting = Set(recordIDs)
        self.records.removeAll { deleting.contains($0.recordID) }
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
