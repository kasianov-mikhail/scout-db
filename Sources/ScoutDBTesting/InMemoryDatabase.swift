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
            if let dense {
                return dense
            }
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
                guard let position = positions.removeValue(forKey: id) else {
                    continue
                }
                slots[position] = nil
                emptied += 1
                removed = true
            }
            guard removed else {
                return
            }
            dense = nil
            compact()
        }

        private mutating func compact() {
            guard emptied > 64, emptied * 2 >= slots.count else {
                return
            }
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
        var errors: [any Error] = []
        var writeErrors: [any Error] = []
        var pageLimit: Int?
        var unindexed: Set<CKRecord.ID> = []
        var tally = RequestTally()
    }

    private let lock = NSLock()
    private var state = State()

    /// Every call the double has served since the last `resetRequests()`.
    public var requests: RequestTally {
        lock.withLock { state.tally }
    }

    /// Drops the tally so the next call starts a fresh budget, leaving the
    /// stored records where they are.
    public func resetRequests() {
        lock.withLock { state.tally = RequestTally() }
    }

    private func counting<R>(
        _ kind: RequestTally.Kind, carrying carried: (R) -> Int, _ body: () throws -> R
    ) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        do {
            let result = try body()
            state.tally.add(kind, carrying: carried(result))
            return result
        } catch {
            state.tally.fail(kind)
            throw error
        }
    }

    public var records: [CKRecord] {
        get { lock.withLock { state.table.all() } }
        set { lock.withLock { state.table.replaceAll(with: newValue) } }
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

    public func records(matching query: CKQuery, resultsLimit: Int) async throws -> QueryPage {
        try counting(.query, carrying: { $0.matchResults.count }) {
            try popErrorLocked(writing: false)
            return pageLocked(query: query, resultsLimit: resultsLimit)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, resultsLimit: Int) async throws -> QueryPage {
        try counting(.continuation, carrying: { $0.matchResults.count }) {
            try popErrorLocked(writing: false)
            let resumed = LocalQuery.resume(
                indexedLocked(),
                from: cursor,
                resultsLimit: resultsLimit,
                pageLimit: state.pageLimit
            )
            guard let page = resumed else {
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
        let error = writing ? state.writeErrors.popLast() ?? state.errors.popLast() : state.errors.popLast()
        guard let error else {
            return
        }
        throw error
    }

    private func pageLocked(query: CKQuery, resultsLimit: Int) -> QueryPage {
        LocalQuery.page(
            indexedLocked(),
            matching: query,
            resultsLimit: resultsLimit,
            pageLimit: state.pageLimit
        )
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try counting(.modify, carrying: { _ in records.count + recordIDs.count }) {
            try popErrorLocked(writing: true)
            records.forEach(upsertLocked)
            state.table.remove(recordIDs)
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try counting(.conditionalSave, carrying: { $0.count }) {
            var queued: [CKRecord.ID: any Error] = [:]
            let batch = Set(records.map(\.recordID))
            while let next = pendingConflictLocked(in: batch, queued: queued) {
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
                    return (record.recordID, .failure(RecordConflictError(serverRecord: server)))
                }
                upsertLocked(record)
                return (record.recordID, .success(record))
            }
        }
    }

    private static func isTransport(_ error: any Error) -> Bool {
        if error is URLError {
            return true
        }
        guard let error = error as? CKError else {
            return false
        }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(error.code)
    }

    private func pendingConflictLocked(in batch: Set<CKRecord.ID>, queued: [CKRecord.ID: any Error])
        -> RecordConflictError?
    {
        guard let next = (state.writeErrors.last ?? state.errors.last) as? RecordConflictError else {
            return nil
        }
        guard batch.contains(next.serverRecord.recordID), queued[next.serverRecord.recordID] == nil else {
            return nil
        }
        return next
    }

    private func conflictingServerLocked(for record: CKRecord) -> CKRecord? {
        guard let stored = state.table.record(id: record.recordID) else {
            return nil
        }
        guard stored.recordType == record.recordType else {
            return nil
        }
        guard stored.recordVersionTag != record.recordVersionTag else {
            return nil
        }
        return stored.duplicate()
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try counting(.fetch, carrying: { $0 == nil ? 0 : 1 }) {
            try popErrorLocked(writing: false)
            return state.table.record(id: id).map { $0.duplicate() }
        }
    }

    public func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try counting(.fetch, carrying: { $0.count }) {
            try popErrorLocked(writing: false)
            return ids.compactMap { state.table.record(id: $0)?.duplicate() }
        }
    }

    private func upsertLocked(_ record: CKRecord) {
        state.table.put(record)
        record.overrideModificationDate(Date())
        record.overrideChangeTag(UUID().uuidString)
    }
}
