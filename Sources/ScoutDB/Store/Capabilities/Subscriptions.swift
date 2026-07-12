//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    /// Subscribes to server-side changes of an entity, delivered as silent pushes.
    ///
    /// The predicate is built from the same filters a read takes; a filter that can
    /// only run client-side (`like`, `matches`, `isNull`, a payload field, ...)
    /// cannot narrow a push subscription and throws `invalidValue`. A delete in
    /// ScoutDB is a tombstone rewrite, so deletions arrive as record updates.
    ///
    /// Saving under an existing `id` replaces that subscription. Returns the id.
    ///
    @discardableResult
    public func subscribe(entity: String, filters: [Filter] = [], id: String? = nil) async throws -> String {
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
