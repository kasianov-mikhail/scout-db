//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// A change delivered by a push from a `subscribe(entity:)` subscription.
public struct ChangeEvent: Equatable, Sendable {
    public enum Kind: Sendable {
        case created, updated, deleted
    }

    public let kind: Kind
    public let uuid: String
    public let subscriptionID: String?

    /// Parses the userInfo of a remote notification.
    ///
    /// Nil when the payload is not a CloudKit query notification or names no
    /// record. A ScoutDB delete is a tombstone rewrite, so it arrives as
    /// `.updated`; `.deleted` only appears for hard deletes.
    ///
    public init?(userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else {
            return nil
        }
        self.init(notification: notification)
    }

    public init?(notification: CKQueryNotification) {
        self.init(reason: notification.queryNotificationReason, recordName: notification.recordID?.recordName, subscriptionID: notification.subscriptionID)
    }

    /// The mapping behind the notification initializers, from the payload's parts.
    public init?(reason: CKQueryNotification.Reason, recordName: String?, subscriptionID: String?) {
        guard let recordName else { return nil }
        uuid = recordName
        self.subscriptionID = subscriptionID
        kind =
            switch reason {
            case .recordCreated:
                .created
            case .recordDeleted:
                .deleted
            default:
                .updated
            }
    }
}

extension EntityStore {
    /// The live record behind a push event.
    ///
    /// The "push arrived, show the data" bridge; nil for hard deletes and for
    /// records tombstoned by the change.
    ///
    public func record(for event: ChangeEvent) async throws -> EntityRecord? {
        guard event.kind != .deleted else {
            return nil
        }
        return try await fetch(uuid: event.uuid)
    }

    /// The record behind a push, without a fetch when the payload carries it.
    ///
    /// A subscription made with `subscribe(entity:filters:id:projecting:)`
    /// delivers the projected fields inside the notification; they decode
    /// here directly, and the fields the projection dropped read as nil. A
    /// push without fields — an unprojected subscription, or a payload the
    /// transport trimmed — falls back to `fetch(uuid:)`. Nil for hard
    /// deletes, tombstones, and non-query notifications.
    ///
    public func record(fromPush userInfo: [AnyHashable: Any]) async throws -> EntityRecord? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else {
            return nil
        }
        return try await record(for: notification)
    }

    /// The record behind a query notification; see `record(fromPush:)`.
    public func record(for notification: CKQueryNotification) async throws -> EntityRecord? {
        guard notification.queryNotificationReason != .recordDeleted, let uuid = notification.recordID?.recordName else {
            return nil
        }
        let fields = (notification.recordFields ?? [:]).compactMapValues { $0 as? any CKRecordValue }
        return try await record(uuid: uuid, pushedFields: fields)
    }

    func record(uuid: String, pushedFields: [String: any CKRecordValue]) async throws -> EntityRecord? {
        guard let entity = pushedFields["entity"] as? String, pushedFields["schema_version"] != nil else {
            return try await fetch(uuid: uuid)
        }
        let definition = try await registry.definition(for: entity)
        let record = CKRecord(recordType: Entity.recordType, recordID: CKRecord.ID(recordName: uuid))
        for (key, value) in pushedFields {
            record[key] = value
        }
        record["uuid"] = record["uuid"] ?? uuid
        let coder = EntityCoder(keyProvider: keyProvider)
        guard let decoded = try? coder.decode(record, using: definition) else {
            return try await fetch(uuid: uuid)
        }
        return decoded.deleted ? nil : decoded
    }
}
