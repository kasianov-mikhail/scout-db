//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Cloud container")
struct CloudContainerTests {
    @Test("requireAccount passes only with a usable account")
    func requireAccount() async throws {
        try await InMemoryContainer(status: .available).requireAccount()

        let signedOut = InMemoryContainer(status: .noAccount)
        do {
            try await signedOut.requireAccount()
            Issue.record("Expected an AccountUnavailableError")
        } catch let error as AccountUnavailableError {
            #expect(error.status == .noAccount)
        }
    }

    @Test("Account changes reach every updates stream")
    func accountUpdates() async throws {
        let container = InMemoryContainer(status: .available)
        var first = container.accountStatusUpdates().makeAsyncIterator()
        var second = container.accountStatusUpdates().makeAsyncIterator()

        container.setAccountStatus(.noAccount)
        #expect(await first.next() == .noAccount)
        #expect(await second.next() == .noAccount)

        container.setAccountStatus(.available)
        #expect(await first.next() == .available)
        #expect(try await container.accountStatus() == .available)
    }

    @Test("Invitations resolve identities through the container and save the share")
    func inviteToShare() async throws {
        let container = InMemoryContainer()
        guard let database = container.privateDatabase as? InMemoryDatabase else {
            Issue.record("Expected the in-memory double")
            return
        }
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let store = EntityStore(database: database, registry: registry, zoneID: zone)
        try await store.ensureZone()

        // Without a share the invitation fails loudly.
        await #expect(throws: SchemaError.notFound(CKRecordNameZoneWideShare)) {
            try await store.inviteToShare(emails: ["ada@example.com"], via: container)
        }

        try await store.shareZone(title: "Scout")
        let share = try await store.inviteToShare(emails: ["ada@example.com"], phoneNumbers: ["+1555"], via: container)

        // The double cannot fabricate participants, so it records the lookups;
        // the share round-trips through the save either way.
        #expect(container.lookedUpParticipants.count == 2)
        #expect(share.recordID.recordName == CKRecordNameZoneWideShare)
        #expect(try await store.zoneShare() != nil)
    }

    @Test("Share metadata by URL rides the container, and a failed fetch never accepts")
    func shareMetadataByURL() async throws {
        let container = InMemoryContainer()
        let url = URL(string: "https://www.icloud.com/share/abc")!

        // The double cannot fabricate CKShare.Metadata; it records the request
        // and answers unknownItem.
        await #expect(throws: CKError.self) {
            _ = try await container.shareMetadata(for: url)
        }
        #expect(container.requestedShareURLs == [url])

        // acceptShare(at:) rides the same fetch, so its failure surfaces
        // before anything is accepted.
        container.metadataErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            _ = try await container.acceptShare(at: url)
        }
        #expect(container.requestedShareURLs.count == 2)
    }

    @Test("The three databases are distinct stores")
    func distinctDatabases() async throws {
        let container = InMemoryContainer()
        let registry = SchemaRegistry(database: container.privateDatabase)
        try await registry.publish(makePurchaseDefinition())
        let store = EntityStore(database: container.privateDatabase, registry: registry)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        #expect((container.privateDatabase as? InMemoryDatabase)?.records.isEmpty == false)
        #expect((container.publicDatabase as? InMemoryDatabase)?.records.isEmpty == true)
        #expect((container.sharedDatabase as? InMemoryDatabase)?.records.isEmpty == true)
    }
}
