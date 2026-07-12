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
    public var storedSubscriptions: [CKSubscription] = []
    public var zones: [CKRecordZone.ID] = []
    private var changeLog: [(sequence: Int64, id: CKRecord.ID, deleted: Bool)] = []
    private var sequence: Int64 = 0
    public var errors: [Error] = []
    public var writeErrors: [Error] = []

    /// Caps every response page the way the CloudKit server does, so tests can
    /// force multi-page reads even for requests made at
    /// `CKQueryOperation.maximumResults`. `nil` leaves only `resultsLimit` in effect.
    public var pageLimit: Int?

    public init() {}

    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        return page(query: query, zoneID: zoneID, desiredKeys: desiredKeys, offset: 0, resultsLimit: resultsLimit)
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        guard case .offset(let query, let zoneID, let offset) = cursor else { throw CKError(.invalidArguments) }
        return page(query: query, zoneID: zoneID, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit)
    }

    // Re-evaluates the query and serves one page from `offset`, mirroring the
    // server: at most `resultsLimit` records per response (`maximumResults`, i.e.
    // 0, means "as many as fit under `pageLimit`") and a cursor whenever matches
    // remain beyond the page. A zone scopes the scan; nil searches all zones.
    private func page(query: CKQuery, zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, offset: Int, resultsLimit: Int) -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        let matched =
            records
            .filter { zoneID == nil || $0.recordID.zoneID == zoneID }
            .filter { $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true }
            .sorted(by: query.sortDescriptors ?? [])
        let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
        let page = matched.dropFirst(offset).prefix(capacity).map { project($0, keys: desiredKeys) }
        let end = offset + page.count
        let cursor: QueryCursor? = end < matched.count ? .offset(query: query, zoneID: zoneID, offset: end) : nil
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
        for id in recordIDs {
            sequence += 1
            changeLog.append((sequence, id, true))
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            // A queued conflict fails only the record it names, mirroring the
            // per-record results of a non-atomic CloudKit save; anything else
            // fails the whole call the way `save` does.
            guard let conflict = error as? RecordConflictError else { throw error }
            return records.map { record in
                guard record.recordID == conflict.serverRecord.recordID else {
                    upsert(record)
                    return (record.recordID, .success(record))
                }
                return (record.recordID, .failure(conflict))
            }
        }
        records.forEach(upsert)
        return records.map { ($0.recordID, .success($0)) }
    }

    public func save(subscription: CKSubscription) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        storedSubscriptions.removeAll { $0.subscriptionID == subscription.subscriptionID }
        storedSubscriptions.append(subscription)
    }

    public func deleteSubscription(id: CKSubscription.ID) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        storedSubscriptions.removeAll { $0.subscriptionID == id }
    }

    public func subscriptions() async throws -> [CKSubscription] {
        if let error = errors.popLast() {
            throw error
        }
        return storedSubscriptions
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        if let error = errors.popLast() {
            throw error
        }
        return records.first { $0.recordID == id }?.copy() as? CKRecord
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?) async throws -> (changed: [CKRecord], deleted: [CKRecord.ID], token: Data?) {
        if let error = errors.popLast() {
            throw error
        }
        let floor = token.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        // Latest state per record wins, mirroring the server's coalesced feed.
        var latest: [CKRecord.ID: Bool] = [:]
        for entry in changeLog where entry.sequence > floor && entry.id.zoneID == zoneID {
            latest[entry.id] = entry.deleted
        }
        let changed = latest.filter { !$0.value }.keys.compactMap { id in records.first { $0.recordID == id }?.copy() as? CKRecord }
        let deleted = latest.filter(\.value).keys.sorted { $0.recordName < $1.recordName }
        return (changed.sorted { $0.recordID.recordName < $1.recordID.recordName }, Array(deleted), Data("\(sequence)".utf8))
    }

    public func save(zone: CKRecordZone) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        if !zones.contains(zone.zoneID) {
            zones.append(zone.zoneID)
        }
    }

    private func upsert(_ record: CKRecord) {
        records.removeAll { $0.recordType == record.recordType && $0.recordID == record.recordID }
        records.append(record)
        sequence += 1
        changeLog.append((sequence, record.recordID, false))
    }

    // Every response hands out a copy, the way the server returns a fresh record
    // per fetch — mutating a query result must not silently edit the store. The
    // envelope overrides live outside the record's own coding, so they are
    // carried over by hand.
    private func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        let projected: CKRecord
        if let keys {
            projected = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() where keys.contains(key) {
                projected[key] = record[key]
            }
        } else {
            projected = record.copy() as! CKRecord
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
