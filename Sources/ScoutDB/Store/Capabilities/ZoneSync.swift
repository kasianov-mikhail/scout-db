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

extension ZoneDelta {
    /// The delta's live records of one entity, decoded into its Swift type.
    ///
    /// Tombstones are skipped — collect them from `deletedIDs(of:)` — and so
    /// are records of other entities, so one delta serves several typed calls.
    /// On a projected pass the fields the projection dropped decode as nil.
    ///
    public func items<T: EntityRepresentable>(_ type: T.Type = T.self) -> [T] {
        records.filter { $0.entity == T.entityName && !$0.deleted }.map(T.init(record:))
    }

    /// The uuids of the entity's records this delta tombstoned.
    ///
    /// CloudKit hard deletes carry no entity name and stay in `deleted`.
    ///
    public func deletedIDs<T: EntityRepresentable>(of type: T.Type = T.self) -> [String] {
        records.filter { $0.entity == T.entityName && $0.deleted }.map(\.uuid)
    }
}

/// The fields one entity contributes to a projected zone pass.
public struct SyncProjection: Sendable {
    public let entity: String
    public let fields: [String]

    public init(entity: String, fields: [String]) {
        self.entity = entity
        self.fields = fields
    }
}

extension EntityStore {
    /// Fetches everything that changed in the store's zone since the token —
    /// every entity in one round trip, unlike the per-entity `changes(entity:since:)`.
    ///
    /// A nil token replays the zone from the beginning. Records of retired or
    /// unknown entities are skipped.
    ///
    public func zoneChanges(since token: Data? = nil) async throws -> ZoneDelta {
        try await zoneChanges(since: token, desiredKeys: nil)
    }

    /// A projected zone pass: changed records carry only the projected fields.
    ///
    /// Use it when the pass drives something light — badges, counters, list
    /// rows — and full records would drag assets and payload blobs over the
    /// wire. Entities outside the projections still appear, envelope-only.
    /// Do not write a projected record back whole: the fields the projection
    /// dropped read as cleared.
    ///
    public func zoneChanges(since token: Data? = nil, projecting projections: [SyncProjection]) async throws -> ZoneDelta {
        var keys = EntityCoder.envelopeKeys
        for projection in projections {
            let definition = try await registry.definition(for: projection.entity)
            keys += try desiredKeys(projection.fields, using: definition).filter { !keys.contains($0) }
        }
        return try await zoneChanges(since: token, desiredKeys: keys)
    }

    private func zoneChanges(since token: Data?, desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneDelta {
        guard let zoneID else {
            throw SchemaError.invalidDefinition("Zone sync requires a store configured with a custom zone")
        }
        let (changed, deleted, next) = try await database.zoneChanges(zoneID: zoneID, since: token, desiredKeys: desiredKeys)
        var records: [EntityRecord] = []
        for record in changed where record.recordType == Entity.recordType {
            guard let entity = record["entity"] as? String, let definition = try? await registry.definition(for: entity) else { continue }
            records += try decode([record], using: definition)
        }
        return ZoneDelta(records: records, deleted: deleted.map(\.recordName), token: next)
    }
}
