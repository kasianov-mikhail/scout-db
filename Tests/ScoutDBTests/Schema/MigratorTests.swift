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
        try await store.write([EntityWrite(values: ["user": .string("alice")], uuid: "u-1")], entity: "profile")

        try await registry.publish(makeRenameDefinition(version: 2))
        let migrated = try await migrator.backfill(entity: "profile")
        #expect(migrated == 1)

        let records = try await EntityReader(store: store, entity: "profile").read()
        #expect(records.map(\.schemaVersion) == [2])
        #expect(records.first?.values["user_id"] == .string("alice"))
    }

    @Test("Backfill carries renamed slot values to the new name")
    func rename() async throws {
        try await registry.publish(makeRenameDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write([EntityWrite(values: ["user": .string("bob")], uuid: "u-2")], entity: "profile")

        try await registry.publish(makeRenameDefinition(version: 2))
        try await migrator.backfill(entity: "profile")

        let filter = Filter(field: "user_id", op: .equals, value: .string("bob"))
        let records = try await EntityReader(store: store, entity: "profile").read(any: [[filter]])
        #expect(records.map(\.uuid) == ["u-2"])
    }

    @Test("Rename carries a value into a field with a fresh slot")
    func renameAcrossSlots() async throws {
        try await registry.publish(makeReslotDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write([EntityWrite(values: ["user": .string("dana")], uuid: "u-4")], entity: "member")

        try await registry.publish(makeReslotDefinition(version: 2))
        let migrated = try await migrator.rename(entity: "member", from: "user", to: "handle")
        #expect(migrated == 1)

        let records = try await EntityReader(store: store, entity: "member").read()
        #expect(records.map(\.schemaVersion) == [2])
        #expect(records.first?.values["handle"] == .string("dana"))
        #expect(records.first?.values["user"] == nil)

        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await migrator.rename(entity: "member", from: "user", to: "ghost")
        }
    }

    @Test("Backfill applies the transform for type changes")
    func typeChange() async throws {
        try await registry.publish(makeRetypeDefinition(version: 1))
        let store = EntityStore(database: database, registry: registry)
        try await store.write([EntityWrite(values: ["amount": .int(500)], uuid: "m-1")], entity: "payment")

        try await registry.publish(makeRetypeDefinition(version: 2))
        try await migrator.backfill(entity: "payment") { record in
            guard case .int(let cents)? = record.values["amount"] else {
                return
            }
            record.values["amount"] = .double(Double(cents) / 100)
        }

        let records = try await EntityReader(store: store, entity: "payment").read()
        #expect(records.first?.values["amount"] == .double(5))
    }

    @Test("Backfill skips records already at the latest version")
    func idempotence() async throws {
        try await registry.publish(makeRenameDefinition(version: 2))
        let store = EntityStore(database: database, registry: registry)
        try await store.write([EntityWrite(values: ["user_id": .string("carol")], uuid: "u-3")], entity: "profile")

        let migrated = try await migrator.backfill(entity: "profile")
        #expect(migrated == 0)
    }

    @Test("View backfill recounts existing records into a freshly declared view")
    func viewBackfill() async throws {
        var definition = makeDefinition(
            entity: "sale",
            fields: [
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
            ],
            views: [AggregateView(name: "all_time")]
        )
        try await registry.publish(definition)
        let store = EntityStore(database: database, registry: registry)
        try await store.write(
            [EntityWrite(values: ["product": .string("app"), "amount": .double(10)])], entity: "sale")
        try await store.write([EntityWrite(values: ["product": .string("app"), "amount": .double(5)])], entity: "sale")
        try await store.write(
            [EntityWrite(values: ["product": .string("book"), "amount": .double(2)])], entity: "sale")

        definition.views? += [AggregateView(name: "by_product", groupBy: "product", sum: "amount")]
        try await registry.publish(definition)
        #expect(try await EntityAggregator(store, entity: "sale", view: "by_product").totals().isEmpty)

        #expect(try await migrator.backfill(view: "by_product", entity: "sale") == 3)
        var totals = try await EntityAggregator(store, entity: "sale", view: "by_product").totals()
        #expect(totals.first { $0.group == "app" }?.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 15)
        #expect(totals.first { $0.group == "book" }?.count == 1)
        #expect(try await EntityAggregator(store, entity: "sale", view: "all_time").totals().map(\.count) == [3])

        #expect(try await migrator.backfill(view: "by_product", entity: "sale") == 3)
        totals = try await EntityAggregator(store, entity: "sale", view: "by_product").totals()
        #expect(totals.first { $0.group == "app" }?.count == 2)
        #expect(totals.first { $0.group == "app" }?.value == 15)
        #expect(try await EntityAggregator(store, entity: "sale", view: "all_time").totals().map(\.count) == [3])

        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await migrator.backfill(view: "ghost", entity: "sale")
        }
    }
}

func makeRenameDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "profile",
        version: version,
        fields: [
            FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00"), until: 2),
            FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00"), since: 2),
        ]
    )
}

func makeReslotDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "member",
        version: version,
        fields: [
            FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00"), until: 2),
            FieldDefinition(name: "handle", type: .string, storage: .slot(.string, "s_01"), since: 2),
        ]
    )
}

func makeRetypeDefinition(version: Int) -> EntityDefinition {
    makeDefinition(
        entity: "payment",
        version: version,
        fields: [
            FieldDefinition(name: "amount", type: .int, storage: .slot(.int, "i_00"), until: 2),
            FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00"), since: 2),
        ]
    )
}
