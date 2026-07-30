//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    @discardableResult
    func subscribe(entity: String, filters: [Filter] = [], id: String? = nil, projecting fields: [String]? = nil) async throws -> String {
        let definition = try await registry.definition(for: entity)
        let (server, client) = try split(filters, entity: entity, using: definition)
        guard client.isEmpty else {
            throw SchemaError.invalidValue(client[0].field)
        }

        let subscription = CKQuerySubscription(
            recordType: "Entity",
            predicate: CKQuery(recordType: "Entity", filters: server).predicate,
            subscriptionID: id ?? "scout-\(entity)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        if let fields {
            info.desiredKeys = try desiredKeys(fields, using: definition)
        }
        subscription.notificationInfo = info

        try await database.save(subscription: subscription)
        return subscription.subscriptionID
    }

    /// Removes a subscription created with `subscribe`.
    public func unsubscribe(id: String) async throws {
        try await database.deleteSubscription(id: id)
    }

    /// The subscriptions currently registered with the database.
    public func subscriptions() async throws -> [CKSubscription] {
        try await database.subscriptions()
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
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: uuid))
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

extension QueryBuilder {
    /// Registers a server-side subscription for the query, and returns its id.
    ///
    /// The device is pushed a notification whenever a record the query matches
    /// is written, changed or deleted. Every filter has to be one the server can
    /// answer — a subscription has no client to fall back on — and a disjunction
    /// cannot be subscribed to at all, since CloudKit takes one predicate per
    /// subscription. `fields` rides the notification itself, so
    /// ``EntityStore/record(fromPush:)`` decodes the change without a fetch.
    ///
    /// Saving under an existing `id` replaces that subscription.
    ///
    /// ```swift
    /// try await store.query("purchase")
    ///     .filter("status" == "paid")
    ///     .subscribe(projecting: ["product_id", "amount"])
    /// ```
    ///
    @discardableResult public func subscribe(id: String? = nil, projecting fields: [String]? = nil) async throws -> String {
        guard let flat else {
            throw SchemaError.invalidDefinition("A subscription carries one server predicate and cannot honor a disjunction")
        }
        return try await store.subscribe(
            entity: entity,
            filters: flat,
            id: id,
            projecting: fields ?? projection
        )
    }
}
