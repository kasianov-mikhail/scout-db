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

struct StaticKeyProvider: EncryptionKeyProvider {
    let keys: [String: SymmetricKey]

    func key(for keyID: String) throws -> SymmetricKey {
        guard let key = keys[keyID] else { throw SchemaError.missingKey(keyID) }
        return key
    }
}

@Suite("EntityStore")
struct EntityStoreTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("Registered definition serves the store without touching Meta")
    func register() async throws {
        let registry = SchemaRegistry(database: InMemoryDatabase())
        try await registry.register(makePurchaseDefinition())

        let local = EntityStore(database: database, registry: registry)
        try await local.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        #expect(try await local.read(entity: "purchase").count == 1)
    }

    @Test("Write persists a single Item record")
    func write() async throws {
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        #expect(database.records.filter { $0.recordType == "Item" }.count == 1)
    }

    @Test("A batched write persists every Item and returns uuids in batch order")
    func batchWrite() async throws {
        let uuids = try await store.write(
            [
                EntityWrite(values: makePurchase(uuid: "p-1").values, uuid: "p-1"),
                EntityWrite(values: makePurchase(uuid: "p-2").values, uuid: "p-2"),
                EntityWrite(values: makePurchase(uuid: "p-3").values, uuid: "p-3"),
            ], entity: "purchase")

        #expect(uuids == ["p-1", "p-2", "p-3"])
        #expect(database.records.filter { $0.recordType == "Item" }.count == 3)
    }

    @Test("An empty batch writes nothing")
    func emptyBatch() async throws {
        let uuids = try await store.write([], entity: "purchase")
        #expect(uuids.count == 0)
        #expect(database.records.filter { $0.recordType == "Item" }.count == 0)
    }

    @Test("Read restores entity records")
    func read() async throws {
        let purchase = makePurchase()
        try await store.write(purchase.values, entity: "purchase", uuid: "p-1")
        let records = try await store.read(entity: "purchase")
        #expect(records == [purchase])
    }

    @Test("Read filters on a slot field")
    func filteredRead() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write(other, entity: "purchase", uuid: "p-2")

        let filter = EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-7"))
        let records = try await store.read(entity: "purchase", filters: [filter])
        #expect(records.map(\.uuid) == ["p-2"])
    }

    @Test("Filters combine across value types in one query")
    func mixedFilters() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        var cheap = makePurchase(uuid: "p-2").values
        cheap["quantity"] = .int(1)
        try await store.write(cheap, entity: "purchase", uuid: "p-2")

        let filters = [
            EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42")),
            EntityStore.Filter(field: "quantity", op: .greaterThan, value: .int(1)),
            EntityStore.Filter(field: "date", op: .greaterThan, value: .date(Date(timeIntervalSince1970: 500_000))),
        ]
        let records = try await store.read(entity: "purchase", filters: filters)
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("Sort orders records server-side")
    func sorted() async throws {
        for (index, quantity) in [3, 1, 2].enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let ascending = try await store.read(entity: "purchase", sort: [EntityStore.Sort(field: "quantity")])
        #expect(ascending.map(\.uuid) == ["p-1", "p-2", "p-0"])

        let descending = try await store.read(entity: "purchase", sort: [EntityStore.Sort(field: "quantity", ascending: false)])
        #expect(descending.map(\.uuid) == ["p-0", "p-2", "p-1"])
    }

    @Test("Sorting on an unknown field fails")
    func sortUnknownField() async throws {
        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await store.read(entity: "purchase", sort: [EntityStore.Sort(field: "ghost")])
        }
    }

    @Test("OR fans out branches and unions results")
    func orBranches() async throws {
        for (index, sku) in ["sku-1", "sku-2", "sku-3"].enumerated() {
            var values = makePurchase().values
            values["product_id"] = .string(sku)
            values["quantity"] = .int(Int64(index + 1))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let branches = [
            [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-1"))],
            [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-3"))],
            [EntityStore.Filter(field: "quantity", op: .greaterThan, value: .int(2))],
        ]
        let records = try await store.read(entity: "purchase", any: branches, sort: [EntityStore.Sort(field: "quantity")])
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("NOT IN excludes listed values server-side")
    func notIn() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        var other = makePurchase(uuid: "p-2").values
        other["product_id"] = .string("sku-7")
        try await store.write(other, entity: "purchase", uuid: "p-2")

        let filter = EntityStore.Filter(field: "product_id", op: .notIn, value: .strings(["sku-42"]))
        let records = try await store.read(entity: "purchase", filters: [filter])
        #expect(records.map(\.uuid) == ["p-2"])
    }

    @Test("BETWEEN expands into a half-open range")
    func between() async throws {
        for (index, seconds) in [1_000, 2_000, 3_000].enumerated() {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }
        let range = EntityStore.Filter.between("date", .date(Date(timeIntervalSince1970: 1_500)), .date(Date(timeIntervalSince1970: 3_000)))
        let records = try await store.read(entity: "purchase", filters: range)
        #expect(records.map(\.uuid) == ["p-1"])
    }

    @Test("containsAll and containsAny cover tag conjunction and disjunction")
    func tagCombinators() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "post",
                fields: [
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00"))
                ]))
        try await store.write(["tags": .strings(["swift", "ios"])], entity: "post", uuid: "n-1")
        try await store.write(["tags": .strings(["swift", "server"])], entity: "post", uuid: "n-2")
        try await store.write(["tags": .strings(["android"])], entity: "post", uuid: "n-3")

        let both = try await store.read(entity: "post", filters: EntityStore.Filter.containsAll("tags", ["swift", "ios"]))
        #expect(both.map(\.uuid) == ["n-1"])

        let either = try await store.read(entity: "post", any: EntityStore.Filter.containsAny("tags", ["ios", "server"]))
        #expect(Set(either.map(\.uuid)) == ["n-1", "n-2"])
    }

    @Test("Numeric and date arrays round-trip and filter with contains")
    func numericArrays() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "sample",
                fields: [
                    FieldDefinition(name: "codes", type: .intList, storage: .slot(.intList, "li_00")),
                    FieldDefinition(name: "scores", type: .doubleList, storage: .slot(.doubleList, "ld_00")),
                    FieldDefinition(name: "times", type: .timestampList, storage: .slot(.timestampList, "lt_00")),
                ]))
        let t0 = Date(timeIntervalSince1970: 1_000)
        try await store.write(["codes": .ints([1, 2, 3]), "scores": .doubles([9.5]), "times": .dates([t0])], entity: "sample", uuid: "s-1")
        try await store.write(["codes": .ints([4, 5]), "scores": .doubles([1.0]), "times": .dates([])], entity: "sample", uuid: "s-2")

        let record = try #require(try await store.read(entity: "sample").first { $0.uuid == "s-1" })
        #expect(record.values["codes"] == .ints([1, 2, 3]))
        #expect(record.values["scores"] == .doubles([9.5]))
        #expect(record.values["times"] == .dates([t0]))

        let filter = EntityStore.Filter(field: "codes", op: .contains, value: .int(2))
        let matched = try await store.read(entity: "sample", filters: [filter])
        #expect(matched.map(\.uuid) == ["s-1"])
    }

    @Test("Reference scalar and location list round-trip")
    func exoticTypes() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "graph",
                fields: [
                    FieldDefinition(name: "parent", type: .reference, storage: .slot(.reference, "r_00")),
                    FieldDefinition(name: "route", type: .locationList, storage: .slot(.locationList, "lg_00")),
                ]))
        let route = [GeoPoint(latitude: 1, longitude: 2), GeoPoint(latitude: 3, longitude: 4)]
        try await store.write(
            [
                "parent": .reference("node-9"),
                "route": .locations(route),
            ], entity: "graph", uuid: "g-1")

        let record = try #require(try await store.read(entity: "graph").first)
        #expect(record.values["parent"] == .reference("node-9"))
        #expect(record.values["route"] == .locations(route))
    }

    @Test("A scalar bytes field lives in its own slot")
    func bytesSlot() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "blob",
                fields: [
                    FieldDefinition(name: "digest", type: .bytes, storage: .slot(.bytes, "b_00"))
                ]))
        let payload = Data([0xDE, 0xAD])
        try await store.write(["digest": .bytes(payload)], entity: "blob", uuid: "b-1")
        let record = try #require(try await store.read(entity: "blob").first)
        #expect(record.values["digest"] == .bytes(payload))
    }

    @Test("Filtering on an unknown field fails")
    func unknownFilter() async throws {
        let filter = EntityStore.Filter(field: "ghost", op: .equals, value: .string("x"))
        await #expect(throws: SchemaError.unknownField("ghost")) {
            try await store.read(entity: "purchase", filters: [filter])
        }
    }

    @Test("Reading an unpublished entity fails")
    func unknownEntity() async throws {
        await #expect(throws: SchemaError.unknownEntity("ghost")) {
            try await store.read(entity: "ghost")
        }
    }

    @Test("Unique key turns writes into upserts")
    func uniqueUpsert() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "score", type: .int, storage: .slot(.int, "i_00")),
                ], unique: ["user_id"]))

        let first = try await store.write(["user_id": .string("alice"), "score": .int(1)], entity: "profile")
        let second = try await store.write(["user_id": .string("alice"), "score": .int(2)], entity: "profile")
        #expect(first == second)

        let records = try await store.read(entity: "profile")
        #expect(records.count == 1)
        #expect(records.first?.values["score"] == .int(2))
    }

    @Test("Deleted records disappear from reads")
    func tombstone() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        try await store.delete(entity: "purchase", uuid: "p-1")
        let records = try await store.read(entity: "purchase")
        #expect(records.count == 0)
    }

    @Test("Change feed returns records after the cursor with tombstones")
    func changeFeed() async throws {
        try await store.write(makePurchase(uuid: "p-1").values, entity: "purchase", uuid: "p-1")
        try await store.write(makePurchase(uuid: "p-2").values, entity: "purchase", uuid: "p-2")
        try await store.delete(entity: "purchase", uuid: "p-1")
        stampModTime(uuid: "p-1", at: Date(timeIntervalSince1970: 100))
        stampModTime(uuid: "p-2", at: Date(timeIntervalSince1970: 200))

        let (all, cursor) = try await store.changes(entity: "purchase")
        #expect(all.count == 2)
        #expect(all.first { $0.uuid == "p-1" }?.deleted == true)
        #expect(cursor == Date(timeIntervalSince1970: 200))

        let (tail, _) = try await store.changes(entity: "purchase", since: Date(timeIntervalSince1970: 150))
        #expect(tail.map(\.uuid) == ["p-2"])
    }

    @Test("List fields support server-side contains filters")
    func tags() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "post",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                ]))
        try await store.write(["title": .string("Intro"), "tags": .strings(["swift", "ios"])], entity: "post", uuid: "n-1")
        try await store.write(["title": .string("Server"), "tags": .strings(["vapor"])], entity: "post", uuid: "n-2")

        let filter = EntityStore.Filter(field: "tags", op: .contains, value: .string("swift"))
        let records = try await store.read(entity: "post", filters: [filter])
        #expect(records.map(\.uuid) == ["n-1"])
    }

    @Test("Location fields support radius queries")
    func radiusQuery() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "store_visit",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "place", type: .location, storage: .slot(.location, "g_00")),
                ]))
        try await store.write(["name": .string("moscow"), "place": .location(latitude: 55.751, longitude: 37.617)], entity: "store_visit", uuid: "v-1")
        try await store.write(["name": .string("spb"), "place": .location(latitude: 59.939, longitude: 30.315)], entity: "store_visit", uuid: "v-2")

        let center = RecordValue.location(latitude: 55.75, longitude: 37.62)
        let filter = EntityStore.Filter(field: "place", op: .near, value: center, radius: 5_000)
        let records = try await store.read(entity: "store_visit", filters: [filter])
        #expect(records.map(\.uuid) == ["v-1"])
    }

    @Test("Aggregate views count writes into grid cells")
    func aggregation() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "tap",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: [AggregateView(name: "hourly", groupBy: "name")]))

        let date = Date(timeIntervalSince1970: 36_000)
        try await store.write(["name": .string("open"), "date": .date(date)], entity: "tap")
        try await store.write(["name": .string("open"), "date": .date(date)], entity: "tap")

        let grids = database.records.filter { $0.recordType == "GridItem" }
        #expect(grids.count == 1)
        #expect(grids.first?["c_10"] == Int64(2))
        #expect(grids.first?["group_key"] == "open")
    }

    @Test("Sum views accumulate values into double cells")
    func sumView() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "payment",
                fields: [
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: [AggregateView(name: "hourly", sum: "amount")]))

        let date = Date(timeIntervalSince1970: 36_000)
        try await store.write(["amount": .double(2.5), "date": .date(date)], entity: "payment")
        try await store.write(["amount": .double(1.5), "date": .date(date)], entity: "payment")

        let grids = database.records.filter { $0.recordType == "GridItem" }
        #expect(grids.count == 1)
        #expect(grids.first?["c_10"] == Int64(2))
        #expect(grids.first?["f_10"] == 4.0)
    }

    @Test("Asset fields round-trip through the envelope")
    func asset() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "report",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "dump", type: .asset, storage: .slot(.asset, "a_00")),
                ]))
        let url = URL(fileURLWithPath: "/tmp/dump.bin")
        try await store.write(["name": .string("crash"), "dump": .asset(url)], entity: "report", uuid: "r-1")

        let records = try await store.read(entity: "report")
        #expect(records.first?.values["dump"] == .asset(url))
        let item = try #require(database.records.first { $0.recordID.recordName == "r-1" })
        #expect((item["a_00"] as? CKAsset)?.fileURL == url)
    }

    @Test("Weekday bucket counts into a weekly grid")
    func weekdayBucket() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "visit",
                fields: [
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"))
                ], envelopeDate: "date", views: [AggregateView(name: "weekly", bucket: .weekday)]))

        let thursday = Date(timeIntervalSince1970: 36_000)
        try await store.write(["date": .date(thursday)], entity: "visit")

        let grids = database.records.filter { $0.recordType == "GridItem" }
        #expect(grids.first?["c_04"] == Int64(1))
    }

    @Test("Encrypted fields hide plaintext but keep the surrogate filterable")
    func encryption() async throws {
        let provider = StaticKeyProvider(keys: ["k1": SymmetricKey(size: .bits256)])
        let secure = EntityStore(database: database, registry: registry, keyProvider: provider)
        try await registry.publish(
            makeDefinition(
                entity: "account",
                fields: [
                    FieldDefinition(name: "email", type: .string, storage: .payload, encrypted: true),
                    FieldDefinition(name: "email_hash", type: .string, storage: .slot(.string, "s_00"), derived: Derivation(source: "email", transform: .hmac)),
                ], keyID: "k1"))

        try await secure.write(["email": .string("alice@example.com")], entity: "account", uuid: "a-1")
        try await secure.write(["email": .string("bob@example.com")], entity: "account", uuid: "a-2")

        for data in database.records.compactMap({ $0["payload"] as Data? }) {
            #expect(!String(decoding: data, as: UTF8.self).contains("alice@"))
        }

        let records = try await secure.read(entity: "account")
        let alice = try #require(records.first { $0.uuid == "a-1" })
        #expect(alice.values["email"] == .string("alice@example.com"))

        let hash = try #require(alice.values["email_hash"])
        let filtered = try await secure.read(entity: "account", filters: [EntityStore.Filter(field: "email_hash", op: .equals, value: hash)])
        #expect(filtered.map(\.uuid) == ["a-1"])

        let blind = try await store.read(entity: "account")
        #expect(blind.first { $0.uuid == "a-1" }?.values["email"] == nil)
    }

    @Test("A keyless update preserves the ciphertext of encrypted fields it cannot read")
    func keylessUpdateKeepsCiphertext() async throws {
        let provider = StaticKeyProvider(keys: ["k1": SymmetricKey(size: .bits256)])
        let secure = EntityStore(database: database, registry: registry, keyProvider: provider)
        try await registry.publish(
            makeDefinition(
                entity: "account",
                fields: [
                    FieldDefinition(name: "email", type: .string, storage: .payload, encrypted: true),
                    FieldDefinition(name: "status", type: .string, storage: .slot(.string, "s_00")),
                ], keyID: "k1"))

        try await secure.write(["email": .string("alice@example.com"), "status": .string("new")], entity: "account", uuid: "a-1")

        // `store` has no key provider, so it reads the encrypted field back as nil.
        try await store.update(entity: "account", uuid: "a-1") { $0.values["status"] = .string("active") }

        let reread = try #require(try await secure.read(entity: "account").first { $0.uuid == "a-1" })
        #expect(reread.values["status"] == .string("active"))
        #expect(reread.values["email"] == .string("alice@example.com"))
    }

    @Test("Writing an encrypted entity without a key fails")
    func encryptionWithoutKey() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "secret",
                fields: [
                    FieldDefinition(name: "token", type: .string, storage: .payload, encrypted: true)
                ], keyID: "k9"))
        await #expect(throws: SchemaError.missingKey("k9")) {
            try await store.write(["token": .string("shh")], entity: "secret")
        }
    }

    private func stampModTime(uuid: String, at date: Date) {
        for record in database.records where record.recordType == "Item" && record.recordID.recordName == uuid {
            record.overrideModificationDate(date)
        }
    }
}
