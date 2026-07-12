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
        // A real conflict carries the winning server record; the retry transforms it.
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server)]
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = .int(9)
        }
        let records = try await store.read(entity: "purchase")
        #expect(records.first?.values["quantity"] == .int(9))
    }

    @Test("A transform that clears fields clears their stored slot and payload values")
    func updateClears() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.update(entity: "purchase", uuid: "p-1") { record in
            record.values["quantity"] = nil
            record.values["comment"] = nil
        }
        let record = try #require(try await store.read(entity: "purchase").first)
        #expect(record.values["quantity"] == nil)
        #expect(record.values["comment"] == nil)
        #expect(record.values["product_id"] == .string("sku-42"))
    }

    @Test("Bulk update retries records that lost their save race")
    func updateAllConflict() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        database.writeErrors = [RecordConflictError(serverRecord: server)]

        let updated = try await store.updateAll(entity: "purchase") { record in
            record.values["quantity"] = .int(9)
        }

        #expect(updated == 2)
        let records = try await store.read(entity: "purchase")
        #expect(records.allSatisfy { $0.values["quantity"] == .int(9) })
    }

    @Test("Bulk update surfaces a conflict that outlives the retries, keeping the saves that landed")
    func updateAllConflictExhausted() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        let server = try #require(database.records.first { $0["uuid"] as? String == "p-1" })
        // Each conflict carries its own copy of the winning record, the way the
        // server materializes one per response.
        database.writeErrors = (0..<3).map { _ in RecordConflictError(serverRecord: server.copy() as! CKRecord) }

        await #expect(throws: RecordConflictError.self) {
            try await store.updateAll(entity: "purchase") { record in
                record.values["quantity"] = .int(9)
            }
        }

        let records = try await store.read(entity: "purchase")
        #expect(records.first { $0.uuid == "p-2" }?.values["quantity"] == .int(9))
        #expect(records.first { $0.uuid == "p-1" }?.values["quantity"] != .int(9))
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

    @Test("Keyset pagination orders by an arbitrary field in both directions")
    func fieldPagination() async throws {
        for (index, quantity) in [3, 1, 2, 2].enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        // Ascending: p-1(1), p-2(2), p-3(2), p-0(3) — the tie falls back to uuids.
        let first = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let second = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 2, after: try #require(first.cursor))
        #expect(second.records.map(\.uuid) == ["p-3", "p-0"])

        let top = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3)
        #expect(top.records.map(\.uuid) == ["p-0", "p-2", "p-3"])
        let rest = try await store.read(entity: "purchase", orderedBy: "quantity", descending: true, limit: 3, after: try #require(top.cursor))
        #expect(rest.records.map(\.uuid) == ["p-1"])
        #expect(rest.cursor == nil)

        // A payload field cannot key a page.
        await #expect(throws: SchemaError.invalidValue("comment")) {
            _ = try await store.read(entity: "purchase", orderedBy: "comment", limit: 1)
        }
    }

    @Test("Filters on payload fields fall back to client-side matching")
    func payloadFilters() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "score", type: .int, storage: .payload),
                    FieldDefinition(name: "tags", type: .stringList, storage: .payload),
                    FieldDefinition(name: "spot", type: .location, storage: .payload),
                ]))
        try await store.write(["name": .string("Ada"), "score": .int(10), "tags": .strings(["swift", "db"])], entity: "profile", uuid: "u-1")
        try await store.write(["name": .string("Bo"), "score": .int(5), "tags": .strings(["db"])], entity: "profile", uuid: "u-2")
        try await store.write(["name": .string("Cy")], entity: "profile", uuid: "u-3")

        func uuids(_ filters: [EntityStore.Filter]) async throws -> [String] {
            try await store.read(entity: "profile", filters: filters).map(\.uuid).sorted()
        }

        #expect(try await uuids([.init(field: "score", op: .equals, value: .int(10))]) == ["u-1"])
        #expect(try await uuids([.init(field: "score", op: .greaterThan, value: .int(4))]) == ["u-1", "u-2"])
        #expect(try await uuids([.init(field: "score", op: .lessThanOrEquals, value: .int(5))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .in, value: .ints([5, 7]))]) == ["u-2"])
        #expect(try await uuids([.init(field: "tags", op: .contains, value: .string("swift"))]) == ["u-1"])
        // A record missing the field never matches, mirroring the server.
        #expect(try await uuids([.init(field: "score", op: .notEquals, value: .int(10))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .notIn, value: .ints([10]))]) == ["u-2"])

        await #expect(throws: SchemaError.invalidValue("spot")) {
            _ = try await store.read(entity: "profile", filters: [.init(field: "spot", op: .near, value: .location(latitude: 0, longitude: 0), radius: 10)])
        }
    }

    @Test("Subscriptions register a server predicate and can be removed")
    func changeSubscriptions() async throws {
        let id = try await store.subscribe(entity: "purchase", filters: [.init(field: "quantity", op: .greaterThan, value: .int(1))])
        #expect(id == "scout-purchase")

        let stored = try #require(database.storedSubscriptions.first as? CKQuerySubscription)
        #expect(stored.predicate.predicateFormat.contains("entity == \"purchase\""))
        #expect(stored.predicate.predicateFormat.contains("i_01"))
        #expect(stored.notificationInfo?.shouldSendContentAvailable == true)
        #expect(try await store.subscriptions().count == 1)

        // A filter that only runs client-side cannot narrow a push subscription.
        await #expect(throws: SchemaError.invalidValue("product_id")) {
            try await store.subscribe(entity: "purchase", filters: [.init(field: "product_id", op: .like, value: .string("sku*"))])
        }

        try await store.unsubscribe(id: id)
        #expect(database.storedSubscriptions.isEmpty)
    }

    @Test("A zoned store keeps entity records and tombstones in its custom zone")
    func customZone() async throws {
        let zone = CKRecordZone.ID(zoneName: "scout", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        try await zoned.ensureZone()
        #expect(database.zones == [zone])

        try await zoned.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let stored = try #require(database.records.first { $0.recordType == "Entity" })
        #expect(stored.recordID.zoneID == zone)
        #expect(try await zoned.read(entity: "purchase").map(\.uuid) == ["p-1"])

        try await zoned.delete(entity: "purchase", uuid: "p-1")
        let tombstone = try #require(database.records.first { $0.recordType == "Entity" })
        #expect(tombstone.recordID.zoneID == zone)
        #expect(try await zoned.read(entity: "purchase").isEmpty)

        // Schema bookkeeping stays in the default zone.
        let descriptor = try #require(database.records.first { $0.recordType == "SchemaDescriptor" })
        #expect(descriptor.recordID.zoneID != zone)
    }

    @Test("Drop tombstones the records and retires the schema; a republish revives the entity")
    func dropEntity() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")

        let dropped = try await store.drop(entity: "purchase")
        #expect(dropped == 2)
        await #expect(throws: SchemaError.unknownEntity("purchase")) {
            _ = try await store.read(entity: "purchase")
        }

        // A fresh registry no longer preloads the retired entity.
        let fresh = SchemaRegistry(database: database)
        try await fresh.preload()
        #expect(await fresh.definitions().isEmpty)

        // Republishing reactivates the schema, without the dropped records.
        try await registry.publish(makePurchaseDefinition())
        #expect(try await store.read(entity: "purchase").isEmpty)

        await #expect(throws: SchemaError.unknownEntity("ghost")) {
            try await registry.retire(entity: "ghost")
        }
    }

    @Test("Fetch by identifier resolves the entity from the record")
    func fetchByUUID() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let record = try await store.fetch(uuid: "p-1")

        #expect(record?.entity == "purchase")
        #expect(record?.values["quantity"] == makePurchase().values["quantity"])
        #expect(try await store.fetch(uuid: "ghost") == nil)
    }

    @Test("Fetch by identifier hides tombstoned records")
    func fetchByUUIDDeleted() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        try await store.delete(entity: "purchase", uuid: "p-1")

        #expect(try await store.fetch(uuid: "p-1") == nil)
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

    @Test("Paginated reads apply client-side filters across pages")
    func paginationWithClientFilter() async throws {
        for index in 0..<4 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            values["comment"] = .string(index % 2 == 0 ? "gift" : "other")
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        // `contains` on a payload field is a client-side matcher, so the page reader has to
        // keep fetching until each page holds `limit` records that survive the filter.
        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        var uuids: [String] = []
        var cursor: EntityCursor?
        repeat {
            let page = try await store.read(entity: "purchase", filters: [filter], limit: 1, after: cursor)
            uuids += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil
        #expect(uuids == ["p-0", "p-2"])
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

    @Test("A transaction mixes writes and deletes in order")
    func transactionDeletes() async throws {
        try await registry.publish(EntityStore.transactionDefinition)
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        try await store.transaction { draft in
            draft.write(makePurchase().values, entity: "purchase", uuid: "p-2")
            draft.delete(entity: "purchase", uuid: "p-1")
        }

        #expect(try await store.read(entity: "purchase").map(\.uuid) == ["p-2"])
        // A replay tombstones the same uuid again — idempotent by design.
        let committed = try await store.read(entity: EntityStore.transactionEntity)
        guard case .bytes(let data)? = committed.first?.values["steps"] else {
            Issue.record("missing steps")
            return
        }
        let steps = try JSONDecoder().decode([TransactionStep].self, from: data)
        #expect(steps.map(\.kind) == [.write, .delete])
    }

    @Test("Steps persisted before deletes existed decode as writes")
    func legacyStepDecoding() throws {
        let legacy = Data(#"{"entity":"purchase","uuid":"p-1","values":{}}"#.utf8)
        let step = try JSONDecoder().decode(TransactionStep.self, from: legacy)
        #expect(step.kind == .write)
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

    @Test("Cascade delete reaches entities not yet cached in the registry")
    func cascadeUncached() async throws {
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

        // A fresh registry has an empty cache; the delete itself only loads the
        // parent's definition, so the cascade must discover 'book' on its own.
        let fresh = EntityStore(database: database, registry: SchemaRegistry(database: database))
        try await fresh.delete(entity: "author", uuid: "a-1", cascade: true)

        #expect(try await store.read(entity: "book").isEmpty)
    }

    @Test("List references join across parents, report orphans, and detach on cascade delete")
    func manyToMany() async throws {
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
                    FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne")], entity: "author", uuid: "a-2")
        try await store.write(["title": .string("Duo"), "author_ids": .strings(["a-1", "a-2"])], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Solo"), "author_ids": .strings(["a-2"])], entity: "book", uuid: "b-2")
        try await store.write(["title": .string("Lost"), "author_ids": .strings(["a-2", "a-9"])], entity: "book", uuid: "b-3")

        let books = try await store.read(entity: "book")
        let parents = try await store.join(entity: "book", records: books, field: "author_ids")
        #expect(parents.keys.sorted() == ["a-1", "a-2"])

        let orphans = try await store.orphans(entity: "book", field: "author_ids")
        #expect(orphans.map(\.uuid) == ["b-3"])

        try await store.delete(entity: "author", uuid: "a-2", cascade: true)
        let remaining = try await store.read(entity: "book")
        #expect(Set(remaining.map(\.uuid)) == ["b-1", "b-2", "b-3"])
        let values = Dictionary(uniqueKeysWithValues: remaining.map { ($0.uuid, $0.values["author_ids"]) })
        #expect(values["b-1"] == .strings(["a-1"]))
        #expect(values["b-2"] == .strings([]))
        #expect(values["b-3"] == .strings(["a-9"]))
    }

    @Test("Children reads the records referencing a parent, scalar and list alike")
    func children() async throws {
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
                    FieldDefinition(name: "editor_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["title": .string("Tom"), "author_id": .string("a-1"), "editor_ids": .strings(["a-2"])], entity: "book", uuid: "b-1")
        try await store.write(["title": .string("Huck"), "author_id": .string("a-2"), "editor_ids": .strings(["a-1", "a-2"])], entity: "book", uuid: "b-2")

        let written = try await store.children(entity: "book", of: "a-1", via: "author_id")
        #expect(written.map(\.uuid) == ["b-1"])

        let edited = try await store.children(entity: "book", of: "a-1", via: "editor_ids")
        #expect(edited.map(\.uuid) == ["b-2"])

        await #expect(throws: SchemaError.unknownField("title")) {
            _ = try await store.children(entity: "book", of: "a-1", via: "title")
        }
    }

    @Test("An enforcing store rejects writes whose references name missing parents")
    func enforcedReferences() async throws {
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
                    FieldDefinition(name: "editor_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                ]))
        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")

        let enforcing = EntityStore(database: database, registry: registry, enforceReferences: true)
        try await enforcing.write(["title": .string("Tom"), "author_id": .string("a-1"), "editor_ids": .strings(["a-1"])], entity: "book", uuid: "b-1")

        await #expect(throws: SchemaError.brokenReference(field: "author_id", key: "a-9")) {
            try await enforcing.write(["title": .string("Lost"), "author_id": .string("a-9")], entity: "book", uuid: "b-2")
        }
        await #expect(throws: SchemaError.brokenReference(field: "editor_ids", key: "a-9")) {
            let values: [String: RecordValue] = ["title": .string("Lost"), "author_id": .string("a-1"), "editor_ids": .strings(["a-1", "a-9"])]
            try await enforcing.write(values, entity: "book", uuid: "b-3")
        }

        // The default store stays permissive.
        try await store.write(["title": .string("Free"), "author_id": .string("a-9")], entity: "book", uuid: "b-4")
        #expect(Set(try await store.read(entity: "book").map(\.uuid)) == ["b-1", "b-4"])
    }

    @Test("An exclusive reference admits one holder, allows re-writes, rejects a second suitor")
    func exclusiveReference() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "person",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "passport",
                fields: [
                    FieldDefinition(name: "number", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "person_id", type: .string, storage: .slot(.string, "s_01"), references: "person", exclusive: true),
                ]))
        try await store.write(["name": .string("Ada")], entity: "person", uuid: "h-1")

        try await store.write(["number": .string("111"), "person_id": .string("h-1")], entity: "passport", uuid: "d-1")
        // The holder may re-write its own reference.
        try await store.write(["number": .string("112"), "person_id": .string("h-1")], entity: "passport", uuid: "d-1")

        await #expect(throws: SchemaError.duplicateReference(field: "person_id", key: "h-1")) {
            try await store.write(["number": .string("222"), "person_id": .string("h-1")], entity: "passport", uuid: "d-2")
        }
        await #expect(throws: SchemaError.duplicateReference(field: "person_id", key: "h-2")) {
            try await store.write(
                [
                    EntityWrite(values: ["number": .string("333"), "person_id": .string("h-2")], uuid: "d-3"),
                    EntityWrite(values: ["number": .string("444"), "person_id": .string("h-2")], uuid: "d-4"),
                ], entity: "passport")
        }
    }

    @Test("A multi-field join resolves every reference in one call")
    func multiJoin() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "author",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "publisher",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))
                ]))
        try await registry.publish(
            makeDefinition(
                entity: "book",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_ids", type: .stringList, storage: .slot(.stringList, "ls_00"), references: "author"),
                    FieldDefinition(name: "publisher_id", type: .string, storage: .slot(.string, "s_01"), references: "publisher"),
                ]))

        try await store.write(["name": .string("Twain")], entity: "author", uuid: "a-1")
        try await store.write(["name": .string("Verne")], entity: "author", uuid: "a-2")
        try await store.write(["name": .string("Salt")], entity: "publisher", uuid: "pub-1")
        try await store.write(
            ["title": .string("Duo"), "author_ids": .strings(["a-1", "a-2"]), "publisher_id": .string("pub-1")], entity: "book", uuid: "b-1")

        let books = try await store.read(entity: "book")
        let joined = try await store.join(entity: "book", records: books, fields: ["author_ids", "publisher_id"])

        #expect(joined["author_ids"]?.keys.sorted() == ["a-1", "a-2"])
        #expect(joined["publisher_id"]?["pub-1"]?.values["name"] == .string("Salt"))
    }

    @Test("Generated Swift source mirrors the definition")
    func codegen() {
        let source = DefinitionCodeGenerator().source(for: makePurchaseDefinition())
        #expect(source.contains("struct Purchase {"))
        #expect(source.contains("var productId: String?"))
        #expect(source.contains("productId = record[\"product_id\"]"))
        #expect(source.contains("var date: Date?"))
        #expect(source.contains("var recordValues: [String: RecordValue] {"))
        #expect(source.contains("values[\"product_id\"] = productId?.recordValue"))
    }

    @Test("Typed lists round-trip through the record subscript")
    func typedListSubscript() {
        var record = EntityRecord(entity: "profile", uuid: "u-1", schemaVersion: 1, values: [:])
        record["tags"] = ["a", "b"]
        record["counts"] = [Int64(1), 2]
        record["rates"] = [1.5, 2.5]
        record["days"] = [Date(timeIntervalSince1970: 0)]

        #expect(record.values["tags"] == .strings(["a", "b"]))
        #expect(record.values["counts"] == .ints([1, 2]))
        #expect(record.values["rates"] == .doubles([1.5, 2.5]))
        #expect(record.values["days"] == .dates([Date(timeIntervalSince1970: 0)]))

        let counts: [Int64]? = record["counts"]
        #expect(counts == [1, 2])
        let plain: [Int]? = record["counts"]
        #expect(plain == [1, 2])
        let rates: [Double]? = record["rates"]
        #expect(rates == [1.5, 2.5])
        let days: [Date]? = record["days"]
        #expect(days == [Date(timeIntervalSince1970: 0)])
        // A kind mismatch reads back as nil, same as the scalar subscript.
        let mismatched: [Int64]? = record["tags"]
        #expect(mismatched == nil)
    }

    private func stampCreator(uuid: String, creator: String) {
        for record in database.records where record.recordType == "Entity" && record.recordID.recordName == uuid {
            record.overrideCreator(creator)
        }
    }
}
