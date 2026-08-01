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

    @Test("The public database backs the store")
    func publicDatabase() async throws {
        let container = InMemoryContainer()
        let registry = SchemaRegistry(database: container.publicDatabase)
        try await registry.publish(makePurchaseDefinition())
        let store = EntityStore(database: container.publicDatabase, registry: registry)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        #expect((container.publicDatabase as? InMemoryDatabase)?.records.isEmpty == false)
    }
}
