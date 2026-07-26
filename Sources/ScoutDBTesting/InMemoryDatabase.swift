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

    /// Reports a lost conditional save the way `CKDatabase` reports it — a raw
    /// `CKError.serverRecordChanged` carrying the server record — rather than a
    /// `RecordConflictError`.
    ///
    /// Both shapes reach `saveIfUnchanged` callers in production, so a test
    /// double that only ever produces the friendlier one hides the paths that
    /// match on the error's type.
    ///
    public var rawConflictErrors = false

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
        guard let page = LocalQuery.resume(records, from: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit, pageLimit: pageLimit) else {
            throw CKError(.invalidArguments)
        }
        return page
    }

    private func page(query: CKQuery, zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, offset: Int, resultsLimit: Int) -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        LocalQuery.page(records, matching: query, inZone: zoneID, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit, pageLimit: pageLimit)
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        }
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
                queued[conflict.serverRecord.recordID] = conflict
            } else if Self.isTransport(error) {
                throw error
            } else {
                queued[records[0].recordID] = error
            }
        }
        return records.map { record in
            if let failure = queued[record.recordID] {
                return (record.recordID, .failure(failure))
            }
            if let server = conflictingServer(for: record) {
                return (record.recordID, .failure(Self.conflict(with: server, raw: rawConflictErrors)))
            }
            upsert(record)
            return (record.recordID, .success(record))
        }
    }

    private static func conflict(with server: CKRecord, raw: Bool) -> any Error {
        guard raw else { return RecordConflictError(serverRecord: server) }
        return CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
    }

    private static func isTransport(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(error.code)
    }

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
        var latest: [CKRecord.ID: (sequence: Int64, deleted: Bool)] = [:]
        for entry in changeLog where entry.sequence > floor && entry.id.zoneID == zoneID {
            latest[entry.id] = (entry.sequence, entry.deleted)
        }
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
        var seen: Set<CKRecordZone.ID> = []
        let changed = zoneLog.filter { $0.sequence > floor }.map(\.zone).filter { seen.insert($0).inserted }
        return (changed.sorted { $0.zoneName < $1.zoneName }, [], Data("\(sequence)".utf8))
    }

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
