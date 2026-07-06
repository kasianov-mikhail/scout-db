//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Migrator")
struct MigratorTests {
    let database = InMemoryDatabase()
    let registry: SchemaRegistry
    let migrator: Migrator

    init() {
        registry = SchemaRegistry(database: database)
        migrator = Migrator(database: database, registry: registry)
    }

    @Test("Backfill rewrites old records at the latest version")
    func backfill() async throws {
        try await registry.publish(makeRenameDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write(["user": .string("alice")], entity: "profile", uuid: "u-1")

        try await registry.publish(makeRenameDefinition(version: 2))
        let migrated = try await migrator.backfill(entity: "profile")
        #expect(migrated == 1)

        let records = try await store.read(entity: "profile")
        #expect(records.map(\.schemaVersion) == [2])
        #expect(records.first?.values["user_id"] == .string("alice"))
    }

    @Test("Backfill carries renamed slot values to the new name")
    func rename() async throws {
        try await registry.publish(makeRenameDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write(["user": .string("bob")], entity: "profile", uuid: "u-2")

        try await registry.publish(makeRenameDefinition(version: 2))
        try await migrator.backfill(entity: "profile")

        let filter = EntityStore.Filter(field: "user_id", op: .equals, value: .string("bob"))
        let records = try await store.read(entity: "profile", filters: [filter])
        #expect(records.map(\.uuid) == ["u-2"])
    }

    @Test("Backfill applies the transform for type changes")
    func typeChange() async throws {
        try await registry.publish(makeRetypeDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write(["amount": .int(500)], entity: "payment", uuid: "m-1")

        try await registry.publish(makeRetypeDefinition(version: 2))
        try await migrator.backfill(entity: "payment") { record in
            guard case .int(let cents)? = record.values["amount"] else { return }
            record.values["amount"] = .double(Double(cents) / 100)
        }

        let records = try await store.read(entity: "payment")
        #expect(records.first?.values["amount"] == .double(5))
    }

    @Test("Backfill skips records already at the latest version")
    func idempotence() async throws {
        try await registry.publish(makeRenameDefinition(version: 2))
        let store = EntityStore(database: database, registry: registry)
        try await store.write(["user_id": .string("carol")], entity: "profile", uuid: "u-3")

        let migrated = try await migrator.backfill(entity: "profile")
        #expect(migrated == 0)
    }

    @Test("A keyless backfill preserves the ciphertext of encrypted fields it cannot read")
    func keylessBackfillKeepsCiphertext() async throws {
        try await registry.publish(makeSecureRenameDefinition(version: 1))
        let provider = StaticKeyProvider(keys: ["k1": SymmetricKey(size: .bits256)])
        let secure = EntityStore(database: database, registry: registry, keyProvider: provider)
        try await secure.write(["email": .string("alice@example.com"), "status": .string("new")], entity: "account", uuid: "a-1")

        try await registry.publish(makeSecureRenameDefinition(version: 2))
        // `migrator` has no key provider, so it reads the encrypted field back as nil.
        let migrated = try await migrator.backfill(entity: "account")
        #expect(migrated == 1)

        let reread = try #require(try await secure.read(entity: "account").first { $0.uuid == "a-1" })
        #expect(reread.schemaVersion == 2)
        #expect(reread.values["state"] == .string("new"))
        #expect(reread.values["email"] == .string("alice@example.com"))
    }
}

func makeRenameDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "profile", version: version,
        fields: [
            FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00"), until: 2),
            FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00"), since: 2),
        ])
}

func makeSecureRenameDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "account", version: version,
        fields: [
            FieldDefinition(name: "email", type: .string, storage: .payload, encrypted: true),
            FieldDefinition(name: "status", type: .string, storage: .slot(.string, "s_00"), until: 2),
            FieldDefinition(name: "state", type: .string, storage: .slot(.string, "s_00"), since: 2),
        ], keyID: "k1")
}

func makeRetypeDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "payment", version: version,
        fields: [
            FieldDefinition(name: "amount", type: .int, storage: .slot(.int, "i_00"), until: 2),
            FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), since: 2),
        ])
}
