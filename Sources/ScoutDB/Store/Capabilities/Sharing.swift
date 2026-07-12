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
}
