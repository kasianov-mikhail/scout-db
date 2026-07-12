//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// One batch of changes from the store's custom zone.
public struct ZoneDelta: Sendable {
    /// Every entity record that changed, tombstones included — a ScoutDB delete
    /// is a rewrite, so it arrives here with `deleted` set.
    public let records: [EntityRecord]
    /// The uuids CloudKit hard-deleted; empty in normal operation.
    public let deleted: [String]
    /// Continuation token for the next call; persist it between launches.
    public let token: Data?
}

extension EntityStore {
    /// Fetches everything that changed in the store's zone since the token —
    /// every entity in one round trip, unlike the per-entity `changes(entity:since:)`.
    ///
    /// A nil token replays the zone from the beginning. Records of retired or
    /// unknown entities are skipped.
    ///
    public func zoneChanges(since token: Data? = nil) async throws -> ZoneDelta {
        guard let zoneID else {
            throw SchemaError.invalidDefinition("Zone sync requires a store configured with a custom zone")
        }
        let (changed, deleted, next) = try await database.zoneChanges(zoneID: zoneID, since: token)
        var records: [EntityRecord] = []
        for record in changed where record.recordType == Entity.recordType {
            guard let entity = record["entity"] as? String, let definition = try? await registry.definition(for: entity) else { continue }
            records += try decode([record], using: definition)
        }
        return ZoneDelta(records: records, deleted: deleted.map(\.recordName), token: next)
    }
}
