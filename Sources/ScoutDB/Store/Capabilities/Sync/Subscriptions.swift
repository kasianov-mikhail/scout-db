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
    package func subscribe(entity: String, filters: [Filter] = [], id: String? = nil, projecting fields: [String]? = nil) async throws -> String {
        let definition = try await registry.definition(for: entity)
        let (server, client) = try split(filters, entity: entity, using: definition)
        guard client.isEmpty else {
            throw SchemaError.invalidValue(client[0].field)
        }

        let subscription = CKQuerySubscription(
            recordType: Entity.recordType,
            predicate: ckQuery(Entity.recordType, filters: server).predicate,
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
