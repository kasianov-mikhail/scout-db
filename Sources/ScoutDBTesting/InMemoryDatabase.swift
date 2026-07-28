//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

/// An in-memory `CloudDatabase` that stands in for CloudKit in tests.
///
/// The double is safe for concurrent use: a lock guards every piece of its
/// mutable state, and each protocol call takes it for the whole operation, so
/// concurrent reads and writes see whole records rather than a half-applied
/// one. That matches what its callers assume — the library fans reads and
/// writes out across task groups — and the settable properties tests poke
/// (`records`, `errors`, `writeErrors`, `pageLimit`) go through the same lock.
///
public final class InMemoryDatabase: CloudDatabase, @unchecked Sendable {
    private struct RecordTable {
        private var slots: [CKRecord?] = []
        private var positions: [CKRecord.ID: Int] = [:]
        private var emptied = 0
        private var dense: [CKRecord]?

        mutating func all() -> [CKRecord] {
            if let dense { return dense }
            let records = slots.compactMap { $0 }
            dense = records
            return records
        }

        func record(id: CKRecord.ID) -> CKRecord? {
            positions[id].flatMap { slots[$0] }
        }

        mutating func replaceAll(with records: [CKRecord]) {
            slots = records
            positions = [:]
            positions.reserveCapacity(records.count)
            for (position, record) in records.enumerated() where positions[record.recordID] == nil {
                positions[record.recordID] = position
            }
            emptied = 0
            dense = records
        }

        mutating func put(_ record: CKRecord) {
            if let position = positions[record.recordID] {
                slots[position] = nil
                emptied += 1
            }
            positions[record.recordID] = slots.count
            slots.append(record)
            dense = nil
            compact()
        }

        mutating func remove(_ ids: some Sequence<CKRecord.ID>) {
            var removed = false
            for id in ids {
                guard let position = positions.removeValue(forKey: id) else { continue }
                slots[position] = nil
                emptied += 1
                removed = true
            }
            guard removed else { return }
            dense = nil
            compact()
        }

        private mutating func compact() {
            guard emptied > 64, emptied * 2 >= slots.count else { return }
            let records = slots.compactMap { $0 }
            positions.removeAll(keepingCapacity: true)
            for (position, record) in records.enumerated() {
                positions[record.recordID] = position
            }
            slots = records
            emptied = 0
        }
    }

    private struct State {
        var table = RecordTable()
        var subscriptions: [CKSubscription] = []
        var errors: [any Error] = []
        var writeErrors: [any Error] = []
        var pageLimit: Int?
        var rawConflictErrors = false
        var unindexed: Set<CKRecord.ID> = []
    }

    private let lock = NSLock()
    private var state = State()

    public var records: [CKRecord] {
        get { lock.withLock { state.table.all() } }
        set { lock.withLock { state.table.replaceAll(with: newValue) } }
    }

    public var storedSubscriptions: [CKSubscription] {
        get { lock.withLock { state.subscriptions } }
        set { lock.withLock { state.subscriptions = newValue } }
    }

    public var errors: [any Error] {
        get { lock.withLock { state.errors } }
        set { lock.withLock { state.errors = newValue } }
    }

    public var writeErrors: [any Error] {
        get { lock.withLock { state.writeErrors } }
        set { lock.withLock { state.writeErrors = newValue } }
    }

    /// Caps every response page the way the CloudKit server does, so tests can
    /// force multi-page reads even for requests made at
    /// `CKQueryOperation.maximumResults`. `nil` leaves only `resultsLimit` in effect.
    public var pageLimit: Int? {
        get { lock.withLock { state.pageLimit } }
        set { lock.withLock { state.pageLimit = newValue } }
    }

    /// Reports a lost conditional save the way `CKDatabase` reports it — a raw
    /// `CKError.serverRecordChanged` carrying the server record — rather than a
    /// `RecordConflictError`.
    ///
    /// Both shapes reach `saveIfUnchanged` callers in production, so a test
    /// double that only ever produces the friendlier one hides the paths that
    /// match on the error's type.
    ///
    public var rawConflictErrors: Bool {
        get { lock.withLock { state.rawConflictErrors } }
        set { lock.withLock { state.rawConflictErrors = newValue } }
    }

    /// Record IDs the query index has not caught up with: absent from every
    /// query response, still reachable by a fetch.
    ///
    /// CloudKit indexes a write asynchronously, so only a fetch by ID reads a
    /// record back immediately. A double that indexes every write on the spot
    /// cannot tell a path that survives the lag from one that reads through the
    /// index.
    ///
    public var unindexed: Set<CKRecord.ID> {
        get { lock.withLock { state.unindexed } }
        set { lock.withLock { state.unindexed = newValue } }
    }

    public init() {}

    public func records(matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try lock.withLock {
            try popErrorLocked(writing: false)
            return pageLocked(query: query, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try lock.withLock {
            try popErrorLocked(writing: false)
            guard let page = LocalQuery.resume(indexedLocked(), from: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit, pageLimit: state.pageLimit)
            else {
                throw CKError(.invalidArguments)
            }
            return page
        }
    }

    private func indexedLocked() -> [CKRecord] {
        let records = state.table.all()
        return state.unindexed.isEmpty ? records : records.filter { !state.unindexed.contains($0.recordID) }
    }

    private func popErrorLocked(writing: Bool) throws {
        guard let error = writing ? state.writeErrors.popLast() ?? state.errors.popLast() : state.errors.popLast() else { return }
        throw error
    }

    private func pageLocked(query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        LocalQuery.page(indexedLocked(), matching: query, desiredKeys: desiredKeys, resultsLimit: resultsLimit, pageLimit: state.pageLimit)
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        try lock.withLock {
            try popErrorLocked(writing: true)
            if let server = conflictingServerLocked(for: record) {
                throw RecordConflictError(serverRecord: server)
            }
            upsertLocked(record)
            return record
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try lock.withLock {
            try popErrorLocked(writing: true)
            records.forEach(upsertLocked)
            state.table.remove(recordIDs)
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try lock.withLock {
            var queued: [CKRecord.ID: any Error] = [:]
            let batch = Set(records.map(\.recordID))
            while let next = (state.writeErrors.last ?? state.errors.last) as? RecordConflictError, batch.contains(next.serverRecord.recordID),
                queued[next.serverRecord.recordID] == nil
            {
                if state.writeErrors.isEmpty {
                    state.errors.removeLast()
                } else {
                    state.writeErrors.removeLast()
                }
                queued[next.serverRecord.recordID] = next
            }
            if queued.isEmpty, let error = state.writeErrors.popLast() ?? state.errors.popLast() {
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
                if let server = conflictingServerLocked(for: record) {
                    return (record.recordID, .failure(Self.conflict(with: server, raw: state.rawConflictErrors)))
                }
                upsertLocked(record)
                return (record.recordID, .success(record))
            }
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

    private func conflictingServerLocked(for record: CKRecord) -> CKRecord? {
        guard let stored = state.table.record(id: record.recordID), stored.recordType == record.recordType,
            stored.recordVersionTag != record.recordVersionTag
        else { return nil }
        return project(stored, keys: nil)
    }

    public func save(subscription: CKSubscription) async throws {
        try lock.withLock {
            try popErrorLocked(writing: true)
            state.subscriptions.removeAll { $0.subscriptionID == subscription.subscriptionID }
            state.subscriptions.append(subscription)
        }
    }

    public func deleteSubscription(id: CKSubscription.ID) async throws {
        try lock.withLock {
            try popErrorLocked(writing: true)
            state.subscriptions.removeAll { $0.subscriptionID == id }
        }
    }

    public func subscriptions() async throws -> [CKSubscription] {
        try lock.withLock {
            try popErrorLocked(writing: false)
            return state.subscriptions
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try lock.withLock {
            try popErrorLocked(writing: false)
            return state.table.record(id: id).map { project($0, keys: nil) }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try lock.withLock {
            try popErrorLocked(writing: false)
            return ids.compactMap { state.table.record(id: $0).map { project($0, keys: nil) } }
        }
    }

    private let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("InMemoryAssets-\(UUID().uuidString)", isDirectory: true)

    private func retainingAssets(of record: CKRecord) -> CKRecord {
        let prefix = EntityStore.assetStagingDirectory.standardizedFileURL.path + "/"
        let staged = record.allKeys().filter { key in
            guard let url = (record[key] as? CKAsset)?.fileURL else { return false }
            return url.standardizedFileURL.path.hasPrefix(prefix)
        }
        guard staged.count > 0 else { return record }
        let stored = record.duplicate()
        for key in staged {
            guard let url = (stored[key] as? CKAsset)?.fileURL else { continue }
            let copy = assetDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { continue }
            stored[key] = CKAsset(fileURL: copy)
        }
        return stored
    }

    private func upsertLocked(_ record: CKRecord) {
        let record = retainingAssets(of: record)
        state.table.put(record)
        record.overrideModificationDate(Date())
        record.overrideChangeTag(UUID().uuidString)
    }

    private func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        LocalQuery.project(record, keys: keys)
    }
}
