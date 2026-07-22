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
    private var zoneLog: [(sequence: Int64, zone: CKRecordZone.ID)] = []
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
        LocalQuery.page(records, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit, pageLimit: pageLimit)
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        // The single-record save is conditional, like the CKDatabase conformance
        // that backs it with .ifServerRecordUnchanged.
        if let server = conflictingServer(for: record) {
            throw RecordConflictError(serverRecord: server)
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
            zoneLog.append((sequence, id.zoneID))
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        // This save is non-atomic, so the server answers per record and one call
        // can settle several outcomes at once. Take every queued conflict that
        // names a record of this batch — but only the first per record, so a
        // stack of conflicts aimed at one record still feeds its retries one at
        // a time.
        var queued: [CKRecord.ID: any Error] = [:]
        let batch = Set(records.map(\.recordID))
        while let next = (writeErrors.last ?? errors.last) as? RecordConflictError, batch.contains(next.serverRecord.recordID),
            queued[next.serverRecord.recordID] == nil
        {
            if writeErrors.isEmpty {
                errors.removeLast()
            } else {
                writeErrors.removeLast()
            }
            queued[next.serverRecord.recordID] = next
        }
        if queued.isEmpty, let error = writeErrors.popLast() ?? errors.popLast() {
            if let conflict = error as? RecordConflictError {
                // A conflict aimed at a record outside this batch still applies
                // to the call that drew it.
                queued[conflict.serverRecord.recordID] = conflict
            } else if Self.isTransport(error) {
                // A transport failure takes the whole call down with it.
                throw error
            } else {
                // The server rejecting one record — permission, quota, an invalid
                // argument — is reported against that record, not the batch. A
                // plain error carries no record id, so it lands on the first.
                queued[records[0].recordID] = error
            }
        }
        return records.map { record in
            if let failure = queued[record.recordID] {
                return (record.recordID, .failure(failure))
            }
            if let server = conflictingServer(for: record) {
                return (record.recordID, .failure(RecordConflictError(serverRecord: server)))
            }
            upsert(record)
            return (record.recordID, .success(record))
        }
    }

    // Whether the transport, rather than the request, is at fault — the failures
    // that take a whole CloudKit call down instead of one of its records.
    private static func isTransport(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(error.code)
    }

    // The stored copy that beats a conditional save: present when the incoming
    // record's change tag differs from the server's — the comparison the real
    // ifServerRecordUnchanged policy makes. A record fetched from this database
    // carries the current tag and passes; a fresh or stale one conflicts.
    private func conflictingServer(for record: CKRecord) -> CKRecord? {
        guard let stored = records.first(where: { $0.recordType == record.recordType && $0.recordID == record.recordID }),
            stored.recordVersionTag != record.recordVersionTag
        else { return nil }
        return project(stored, keys: nil)
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
        return records.first { $0.recordID == id }.map { project($0, keys: nil) }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        if let error = errors.popLast() {
            throw error
        }
        let stored = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { stored[$0].map { project($0, keys: nil) } }
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        if let error = errors.popLast() {
            throw error
        }
        let floor = token.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        // Latest state per record wins, mirroring the server's coalesced feed.
        var latest: [CKRecord.ID: (sequence: Int64, deleted: Bool)] = [:]
        for entry in changeLog where entry.sequence > floor && entry.id.zoneID == zoneID {
            latest[entry.id] = (entry.sequence, entry.deleted)
        }
        // A limited pass serves the oldest changes with a token fencing them
        // off, the way the server pages its feed.
        var entries = latest.map { (id: $0.key, sequence: $0.value.sequence, deleted: $0.value.deleted) }.sorted { $0.sequence < $1.sequence }
        var next = sequence
        if let resultsLimit, entries.count > resultsLimit {
            entries = Array(entries.prefix(resultsLimit))
            next = entries.last?.sequence ?? sequence
        }
        let changed = entries.filter { !$0.deleted }.compactMap { entry in records.first { $0.recordID == entry.id }.map { project($0, keys: desiredKeys) } }
        let deleted = entries.filter(\.deleted).map(\.id).sorted { $0.recordName < $1.recordName }
        return (changed.sorted { $0.recordID.recordName < $1.recordID.recordName }, deleted, Data("\(next)".utf8))
    }

    public func save(zone: CKRecordZone) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
        if !zones.contains(zone.zoneID) {
            zones.append(zone.zoneID)
        }
        sequence += 1
        zoneLog.append((sequence, zone.zoneID))
    }

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        if let error = errors.popLast() {
            throw error
        }
        let floor = token.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        // One entry per zone, mirroring the server's coalesced feed; the double
        // never hard-deletes zones, so the deleted list stays empty.
        var seen: Set<CKRecordZone.ID> = []
        let changed = zoneLog.filter { $0.sequence > floor }.map(\.zone).filter { seen.insert($0).inserted }
        return (changed.sorted { $0.zoneName < $1.zoneName }, [], Data("\(sequence)".utf8))
    }

    // The real server uploads asset bytes during the save, so ScoutDB retires
    // its staged files once a write lands. Mirror the upload: store a copy
    // whose staged assets point at private duplicates — without it, every
    // post-save read would dangle. The caller's record stays untouched, the
    // way a CKDatabase save leaves the client record's asset URLs alone.
    private let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("InMemoryAssets-\(UUID().uuidString)", isDirectory: true)

    private func retainingAssets(of record: CKRecord) -> CKRecord {
        let prefix = EntityStore.assetStagingDirectory.standardizedFileURL.path + "/"
        let staged = record.allKeys().filter { key in
            guard let url = (record[key] as? CKAsset)?.fileURL else { return false }
            return url.standardizedFileURL.path.hasPrefix(prefix)
        }
        guard staged.count > 0 else { return record }
        let stored = record.copy() as! CKRecord
        for key in staged {
            guard let url = (stored[key] as? CKAsset)?.fileURL else { continue }
            let copy = assetDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { continue }
            stored[key] = CKAsset(fileURL: copy)
        }
        return stored
    }

    private func upsert(_ record: CKRecord) {
        let record = retainingAssets(of: record)
        records.removeAll { $0.recordType == record.recordType && $0.recordID == record.recordID }
        records.append(record)
        // Stamp the save time and a fresh change tag the way the server does, so
        // `modificationDate` predicates, change feeds, and conditional saves
        // behave in tests; explicit overrides win because they are applied
        // after the write.
        record.overrideModificationDate(Date())
        record.overrideChangeTag(UUID().uuidString)
        sequence += 1
        changeLog.append((sequence, record.recordID, false))
        zoneLog.append((sequence, record.recordID.zoneID))
    }

    private func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        LocalQuery.project(record, keys: keys)
    }
}
