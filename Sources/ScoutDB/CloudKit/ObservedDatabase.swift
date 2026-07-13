//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// One settled database call, as handed to a telemetry observer.
public struct DatabaseOperation: Sendable {
    public enum Kind: String, Sendable {
        case query, continuation, save, modify, conditionalSave
        case subscriptionSave, subscriptionDelete, subscriptionList
        case zoneSave, fetch, zoneChanges, databaseChanges
    }

    public let kind: Kind
    public let duration: Duration
    /// How many records the call carried — results for reads, inputs for writes.
    public let recordCount: Int
    /// The thrown error's description; nil when the call succeeded.
    public let error: String?
}

/// Receives every settled call of an `ObservedDatabase`.
///
/// Called synchronously on the calling task, so implementations should hand
/// the operation off (to a logger, a metrics pipeline) rather than block.
///
public protocol DatabaseObserver: Sendable {
    func record(_ operation: DatabaseOperation)
}

/// A `CloudDatabase` decorator that reports every call to an observer.
///
/// Wrap any layer of the stack: around a `CKDatabase` it measures wire calls,
/// around an `OfflineCache` it sees what the app experiences, queue-served
/// writes included. Composes freely with the other decorators.
///
public final class ObservedDatabase: CloudDatabase, @unchecked Sendable {
    private let backing: any CloudDatabase
    private let observer: any DatabaseObserver

    public init(backing: any CloudDatabase, observer: any DatabaseObserver) {
        self.backing = backing
        self.observer = observer
    }

    private func measure<R>(_ kind: DatabaseOperation.Kind, counting count: (R) -> Int = { _ in 0 }, _ body: () async throws -> R) async throws -> R {
        let start = ContinuousClock.now
        do {
            let result = try await body()
            observer.record(DatabaseOperation(kind: kind, duration: ContinuousClock.now - start, recordCount: count(result), error: nil))
            return result
        } catch {
            observer.record(DatabaseOperation(kind: kind, duration: ContinuousClock.now - start, recordCount: 0, error: "\(error)"))
            throw error
        }
    }

    public func records(matching query: CKQuery, inZone zoneID: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await measure(.query, counting: { $0.matchResults.count }) {
            try await backing.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        }
    }

    public func records(continuingMatchFrom cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?
    ) {
        try await measure(.continuation, counting: { $0.matchResults.count }) {
            try await backing.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
        }
    }

    public func save(_ record: CKRecord) async throws -> CKRecord {
        try await measure(.save, counting: { _ in 1 }) {
            try await backing.save(record)
        }
    }

    public func modifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) async throws {
        try await measure(.modify, counting: { _ in records.count + recordIDs.count }) {
            try await backing.modifyRecords(saving: records, deleting: recordIDs)
        }
    }

    public func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
        try await measure(.conditionalSave, counting: { $0.count }) {
            try await backing.saveIfUnchanged(records)
        }
    }

    public func save(subscription: CKSubscription) async throws {
        try await measure(.subscriptionSave) {
            try await backing.save(subscription: subscription)
        }
    }

    public func deleteSubscription(id: CKSubscription.ID) async throws {
        try await measure(.subscriptionDelete) {
            try await backing.deleteSubscription(id: id)
        }
    }

    public func subscriptions() async throws -> [CKSubscription] {
        try await measure(.subscriptionList, counting: { $0.count }) {
            try await backing.subscriptions()
        }
    }

    public func save(zone: CKRecordZone) async throws {
        try await measure(.zoneSave) {
            try await backing.save(zone: zone)
        }
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        try await measure(.fetch, counting: { $0 == nil ? 0 : 1 }) {
            try await backing.fetchRecord(id: id)
        }
    }

    public func zoneChanges(zoneID: CKRecordZone.ID, since token: Data?, desiredKeys: [CKRecord.FieldKey]?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], token: Data?
    ) {
        try await measure(.zoneChanges, counting: { $0.changed.count + $0.deleted.count }) {
            try await backing.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys)
        }
    }

    public func databaseChanges(since token: Data?) async throws -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: Data?) {
        try await measure(.databaseChanges, counting: { $0.changed.count + $0.deleted.count }) {
            try await backing.databaseChanges(since: token)
        }
    }
}
