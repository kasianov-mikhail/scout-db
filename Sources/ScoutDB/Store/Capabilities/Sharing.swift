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

    /// Shares one record, creating its share on first call.
    ///
    /// The finer-grained sibling of `shareZone()`: participants see this
    /// record, not the whole zone — share one list, not the whole database.
    /// The share and the record save together, as CloudKit requires. Hand
    /// `share.url` to the participants; invite specific people with
    /// `inviteToShare(emails:phoneNumbers:permission:on:via:)`.
    ///
    @discardableResult public func shareRecord(entity: String, uuid: String, title: String? = nil) async throws -> CKShare {
        if let existing = try await recordShare(entity: entity, uuid: uuid) {
            return existing
        }
        let root = try await sharedRoot(entity: entity, uuid: uuid)
        let share = CKShare(rootRecord: root)
        if let title {
            share[CKShare.SystemFieldKey.title] = title
        }
        try await database.write(records: [root, share])
        return share
    }

    /// The record's share, or nil when the record is not shared.
    public func recordShare(entity: String, uuid: String) async throws -> CKShare? {
        guard let reference = try await sharedRoot(entity: entity, uuid: uuid).share else { return nil }
        return try await database.fetchRecord(id: reference.recordID) as? CKShare
    }

    /// Stops sharing the record; participants lose access, the record stays.
    public func stopSharing(entity: String, uuid: String) async throws {
        guard let share = try await recordShare(entity: entity, uuid: uuid) else { return }
        try await database.modifyRecords(saving: [], deleting: [share.recordID])
    }

    // The server copy of a shareable record: sharing needs a custom zone, an
    // existing record, and the entity the caller thinks it is.
    private func sharedRoot(entity: String, uuid: String) async throws -> CKRecord {
        guard let zoneID else {
            throw SchemaError.invalidDefinition("Sharing requires a store configured with a custom zone")
        }
        guard let root = try await database.fetchRecord(id: CKRecord.ID(recordName: uuid, zoneID: zoneID)), root["entity"] as? String == entity
        else {
            throw SchemaError.notFound(uuid)
        }
        return root
    }

    /// Sets what following the share link grants.
    ///
    /// `.readOnly`/`.readWrite` opens the share to everyone with the URL;
    /// `.none` makes it invite-only.
    ///
    public func setSharePublicPermission(_ permission: CKShare.ParticipantPermission, on share: CKShare) async throws {
        share.publicPermission = permission
        try await database.write(record: share)
    }

    /// Sets the zone share's public permission; see `setSharePublicPermission(_:on:)`.
    public func setSharePublicPermission(_ permission: CKShare.ParticipantPermission) async throws {
        guard let share = try await zoneShare() else {
            throw SchemaError.notFound(CKRecordNameZoneWideShare)
        }
        try await setSharePublicPermission(permission, on: share)
    }

    /// Invites people to a share by email or phone — zone-wide and per-record
    /// shares alike.
    ///
    /// Resolves the identities through the container, marks each participant
    /// with `permission`, and saves them onto the share. Hand `share.url` to
    /// the invitees; acceptance runs through the system flow and
    /// `CloudContainer.acceptShare(metadata:)`.
    ///
    @discardableResult public func inviteToShare(
        emails: [String] = [], phoneNumbers: [String] = [], permission: CKShare.ParticipantPermission = .readWrite, on share: CKShare,
        via container: any CloudContainer
    ) async throws -> CKShare {
        let infos = emails.map(CKUserIdentity.LookupInfo.init(emailAddress:)) + phoneNumbers.map(CKUserIdentity.LookupInfo.init(phoneNumber:))
        for participant in try await container.lookUpShareParticipants(infos) {
            participant.permission = permission
            share.addParticipant(participant)
        }
        try await database.write(record: share)
        return share
    }

    /// Invites people to the zone share, which must already exist
    /// (`shareZone()` first); see `inviteToShare(emails:phoneNumbers:permission:on:via:)`.
    @discardableResult public func inviteToShare(
        emails: [String] = [], phoneNumbers: [String] = [], permission: CKShare.ParticipantPermission = .readWrite, via container: any CloudContainer
    ) async throws -> CKShare {
        guard let share = try await zoneShare() else {
            throw SchemaError.notFound(CKRecordNameZoneWideShare)
        }
        return try await inviteToShare(emails: emails, phoneNumbers: phoneNumbers, permission: permission, on: share, via: container)
    }

    /// Removes a participant from a share — zone-wide or per-record.
    ///
    /// The owner cannot be removed — CloudKit raises an unrecoverable exception
    /// for it, so the attempt fails here as a plain error instead.
    ///
    public func removeShareParticipant(_ participant: CKShare.Participant, from share: CKShare) async throws {
        guard participant.role != .owner else {
            throw SchemaError.invalidValue("owner")
        }
        share.removeParticipant(participant)
        try await database.write(record: share)
    }

    /// Removes a participant from the zone share; see `removeShareParticipant(_:from:)`.
    public func removeShareParticipant(_ participant: CKShare.Participant) async throws {
        guard let share = try await zoneShare() else {
            throw SchemaError.notFound(CKRecordNameZoneWideShare)
        }
        try await removeShareParticipant(participant, from: share)
    }
}
