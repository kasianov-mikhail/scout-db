//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    /// Shares the store's custom zone, creating the zone-wide share on first call.
    ///
    /// The share covers every entity record in the zone. Hand `share.url` to the
    /// participants; acceptance and the shared-database view on their side go
    /// through the standard CloudKit flows (`CKShare.Metadata`, `UICloudSharingController`).
    ///
    @discardableResult public func shareZone(title: String? = nil) async throws -> CKShare {
        guard let zoneID else {
            throw SchemaError.invalidDefinition("Sharing requires a store configured with a custom zone")
        }
        if let existing = try await zoneShare() {
            return existing
        }
        let share = CKShare(recordZoneID: zoneID)
        if let title {
            share[CKShare.SystemFieldKey.title] = title
        }
        try await database.write(record: share)
        return share
    }

    /// The zone-wide share, or nil when the zone is not shared (or not configured).
    public func zoneShare() async throws -> CKShare? {
        guard let zoneID else { return nil }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try await database.fetchRecord(id: id) as? CKShare
    }

    /// Stops sharing the zone; participants lose access, the records stay.
    public func stopSharing() async throws {
        guard let share = try await zoneShare() else { return }
        try await database.modifyRecords(saving: [], deleting: [share.recordID])
    }

    /// The participants of the zone share, the owner included; empty when unshared.
    public func shareParticipants() async throws -> [CKShare.Participant] {
        try await zoneShare()?.participants ?? []
    }

    /// Sets what following the share link grants.
    ///
    /// `.readOnly`/`.readWrite` opens the share to everyone with the URL;
    /// `.none` makes it invite-only. Inviting a specific participant needs the
    /// container-scoped lookup (`CKFetchShareParticipantsOperation`), which
    /// stays on the app side.
    ///
    public func setSharePublicPermission(_ permission: CKShare.ParticipantPermission) async throws {
        guard let share = try await zoneShare() else {
            throw SchemaError.notFound(CKRecordNameZoneWideShare)
        }
        share.publicPermission = permission
        try await database.write(record: share)
    }

    /// Removes a participant from the zone share.
    ///
    /// The owner cannot be removed — CloudKit raises an unrecoverable exception
    /// for it, so the attempt fails here as a plain error instead.
    ///
    public func removeShareParticipant(_ participant: CKShare.Participant) async throws {
        guard participant.role != .owner else {
            throw SchemaError.invalidValue("owner")
        }
        guard let share = try await zoneShare() else {
            throw SchemaError.notFound(CKRecordNameZoneWideShare)
        }
        share.removeParticipant(participant)
        try await database.write(record: share)
    }
}
