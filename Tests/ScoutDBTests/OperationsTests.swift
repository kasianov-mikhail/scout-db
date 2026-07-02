//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import Testing

@testable import ScoutDB

@Suite("Operations")
struct OperationsTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("CAS update applies the transform to the stored record")
    func update() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(7)
        }
        let records = try await store.read(entity: "purchase")
        #expect(records.first?.values["quantity"] == .int(7))
    }

    @Test("CAS update retries after a conflict")
    func updateConflict() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        database.writeErrors = [RecordConflictError(serverRecord: CKRecord(recordType: "Item", recordID: CKRecord.ID(recordName: "p-1")))]
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        let records = try await store.read(entity: "purchase")
        #expect(records.first?.values["quantity"] == .int(9))
    }

    @Test("CAS update of a missing record fails")
    func updateMissing() async throws {
        await #expect(throws: SchemaError.notFound("ghost")) {
            try await store.update(entity: "purchase", uuid: "ghost") { _ in }
        }
    }

    @Test("Keyset pagination walks records in date order")
    func pagination() async throws {
        for (index, seconds) in [3_000, 1_000, 2_000].enumerated() {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let first = try await store.read(entity: "purchase", limit: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let cursor = try #require(first.cursor)

        let second = try await store.read(entity: "purchase", limit: 2, after: cursor)
        #expect(second.records.map(\.uuid) == ["p-0"])
        #expect(second.cursor == nil)
    }

    @Test("Reap tombstones expired records")
    func reap() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ping",
                fields: [
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"))
                ], envelopeDate: "date", ttl: 3_600))

        try await store.write(["date": .date(Date(timeIntervalSince1970: 1_000))], entity: "ping", uuid: "old")
        try await store.write(["date": .date(Date(timeIntervalSince1970: 100_000))], entity: "ping", uuid: "new")

        let reaped = try await store.reap(entity: "ping", asOf: Date(timeIntervalSince1970: 50_000))
        #expect(reaped == 1)
        let records = try await store.read(entity: "ping")
        #expect(records.map(\.uuid) == ["new"])
    }

    @Test("Projection fetches only the requested fields")
    func projection() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let slim = try await store.read(entity: "purchase", fields: ["product_id"])
        #expect(slim.first?.values["product_id"] == .string("sku-42"))
        #expect(slim.first?.values["quantity"] == nil)
        #expect(slim.first?.values["comment"] == nil)

        let withPayload = try await store.read(entity: "purchase", fields: ["comment"])
        #expect(withPayload.first?.values["comment"] == .string("gift"))
    }

    @Test("Projection auto-includes filtered fields")
    func projectionWithFilter() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        let records = try await store.read(entity: "purchase", filters: [filter], fields: ["product_id"])
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Explain reveals the server and client sides of a query")
    func explain() async throws {
        let filters = [
            EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42")),
            EntityStore.Filter(field: "comment", op: .contains, value: .string("gif")),
        ]
        let plan = try await store.explain(entity: "purchase", filters: filters, sort: [EntityStore.Sort(field: "date")])
        #expect(plan.server.contains("s_00 equals sku-42"))
        #expect(plan.client.contains("comment contains gif"))
        #expect(plan.sort == ["t_00 asc"])
        #expect(plan.description.contains("SERVER s_00 equals sku-42"))
    }

    @Test("Stream pages through every record in order")
    func stream() async throws {
        for index in 0..<5 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        var uuids: [String] = []
        for try await record in store.stream(entity: "purchase", pageSize: 2) {
            uuids.append(record.uuid)
        }
        #expect(uuids == ["p-0", "p-1", "p-2", "p-3", "p-4"])
    }

    @Test("updateAll rewrites every matching record")
    func updateAll() async throws {
        for index in 0..<3 {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
        }
        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))
        let updated = try await store.updateAll(entity: "purchase", filters: [filter]) { record in
            record.values["quantity"] = .int(99)
        }
        #expect(updated == 3)

        let records = try await store.read(entity: "purchase")
        #expect(records.allSatisfy { $0.values["quantity"] == .int(99) })
    }

    @Test("deleteAll tombstones every matching record")
    func deleteAll() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write(other, entity: "purchase", uuid: "p-2")

        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))
        let deleted = try await store.deleteAll(entity: "purchase", filters: [filter])
        #expect(deleted == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
    }

    @Test("Transaction applies every step and commits")
    func transaction() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        let txn = try await store.transaction { draft in
            draft.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
            draft.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        }

        #expect(try await store.read(entity: "purchase").count == 2)
        let committed = try await store.read(entity: EntityStore.transactionEntity)
        #expect(committed.map(\.uuid) == [txn])
        #expect(committed.first?.values["status"] == .string("committed"))
    }

    @Test("Repair completes an interrupted transaction")
    func repair() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        let steps = try JSONEncoder().encode([TransactionStep(entity: "purchase", uuid: "p-9", values: makePurchase().values)])
        try await store.write(
            ["status": .string("pending"), "date": .date(Date(timeIntervalSince1970: 1_000)), "steps": .bytes(steps)], entity: EntityStore.transactionEntity,
            uuid: "t-1")

        let repaired = try await store.repairTransactions()
        #expect(repaired == 1)
        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-9"])

        let committed = try await store.read(entity: EntityStore.transactionEntity)
        #expect(committed.first?.values["status"] == .string("committed"))
        #expect(try await store.repairTransactions() == 0)
    }

    @Test("Preload warms the cache for every published entity")
    func preload() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "alpha",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "beta",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))

        let fresh = SchemaRegistry(database: database)
        let preloaded = try await fresh.preload()
        #expect(preloaded == 3)
        #expect(Set(await fresh.definitions().map(\.entity)) == ["purchase", "alpha", "beta"])
    }

    @Test("Untrusted writers are filtered out of reads")
    func trustedWriters() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        stampCreator(uuid: "p-1", creator: "good")
        stampCreator(uuid: "p-2", creator: "evil")

        let guarded = EntityStore(database: database, registry: registry, trustedWriters: ["good"])
        let records = try await guarded.read(entity: "purchase")
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Join resolves references, orphans find broken ones, cascade deletes children")
    func relations() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1")], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Lost"), "author_id": .string("a-9")], entity: "book", uuid: "b-2")

        let books = try await store.read(entity: "book")
        let parents = try await store.join(entity: "book", records: books, field: "author_id")
        #expect(parents["a-1"]?.values["name"] == .string("Twain"))

        let orphans = try await store.orphans(entity: "book", field: "author_id")
        #expect(orphans.map(\.uuid) == ["b-2"])

        try await store.delete(entity: "author", uuid: "a-1", cascade: true)
        let remaining = try await store.read(entity: "book")
        #expect(remaining.map(\.uuid) == ["b-2"])
    }

    @Test("Generated Swift source mirrors the definition")
    func codegen() {
        let source = DefinitionCodeGenerator().source(for: makePurchaseDefinition())
        #expect(source.contains("struct Purchase {"))
        #expect(source.contains("var productId: String?"))
        #expect(source.contains("productId = record[\"product_id\"]"))
        #expect(source.contains("var date: Date?"))
    }

    private func stampCreator(uuid: String, creator: String) {
        for record in database.records where record.recordType == "Item" && record.recordID.recordName == uuid {
            record.overrideCreator(creator)
        }
    }
}
