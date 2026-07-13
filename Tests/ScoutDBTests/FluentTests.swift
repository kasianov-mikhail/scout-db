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

@Suite("Fluent interface")
struct FluentTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("quantity", .int, .minimum(0))
            .field("amount", .double)
            .field("date", .timestamp)
            .field("comment", .string, .payload)
            .envelopeDate("date")
            .create()

        for (index, quantity) in [3, 1, 2].enumerated() {
            try await store.write(
                [
                    "product_id": .string("sku-\(index)"),
                    "quantity": .int(Int64(quantity)),
                    "amount": .double(Double(quantity) * 10),
                    "date": .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000))),
                ], entity: "purchase", uuid: "p-\(index)")
        }
    }

    @Test("The schema builder assigns slots in declaration order")
    func slotAllocation() async throws {
        let definition = try await registry.definition(for: "purchase")
        #expect(definition.version == 1)
        #expect(definition.fields.first { $0.name == "product_id" }?.storage == .slot(.string, "s_00"))
        #expect(definition.fields.first { $0.name == "quantity" }?.storage == .slot(.int, "i_00"))
        #expect(definition.fields.first { $0.name == "amount" }?.storage == .slot(.double, "d_00"))
        #expect(definition.fields.first { $0.name == "comment" }?.storage == .payload)
        #expect(definition.fields.first { $0.name == "quantity" }?.minimum == 0)
        #expect(definition.envelopeDate == "date")
    }

    @Test("Query builder filters, sorts, and limits")
    func query() async throws {
        let records = try await store.query("purchase")
            .filter("quantity" > 1)
            .sort("quantity", .descending)
            .limit(1)
            .all()
        #expect(records.map(\.uuid) == ["p-0"])
    }

    @Test("Operator sugar covers ranges and prefixes")
    func operators() async throws {
        #expect(try await store.query("purchase").filter("quantity" >= 2).count() == 2)
        #expect(try await store.query("purchase").filter("quantity" != 2).count() == 2)
        #expect(try await store.query("purchase").filter("product_id" =~ "sku-").count() == 3)
        #expect(try await store.query("purchase").filter("product_id", .equals, "sku-1").count() == 1)
    }

    @Test("first returns the head of the sorted result")
    func first() async throws {
        let record = try await store.query("purchase").sort("date", .descending).first()
        #expect(record?.uuid == "p-2")
    }

    @Test("OR groups distribute over the base filters")
    func orGroup() async throws {
        let records = try await store.query("purchase")
            .filter("quantity" > 0)
            .group {
                $0.filter("product_id", .equals, "sku-0")
                $0.filter("product_id", .equals, "sku-2")
            }
            .sort("date")
            .all()
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("Builder update and delete rewrite matching records")
    func mutation() async throws {
        try await store.query("purchase").filter("quantity" > 1).update { record in
            record.values["quantity"] = .int(9)
        }
        #expect(try await store.query("purchase").filter("quantity", .equals, 9).count() == 2)

        try await store.query("purchase").filter("quantity", .equals, 9).delete()
        #expect(try await store.query("purchase").count() == 1)
    }

    @Test("Exclude negates a predicate and keeps records without the field")
    func excludeFilters() async throws {
        let records = try await store.query("purchase")
            .exclude("product_id", .equals, "sku-1")
            .sort("date")
            .all()
        #expect(records.map(\.uuid) == ["p-0", "p-2"])

        // The complement composes with positive filters and other client ops.
        #expect(try await store.query("purchase").filter("quantity" > 1).exclude("quantity", .equals, 3).count() == 1)
        #expect(try await store.query("purchase").exclude("product_id", .contains, "ku-").count() == 0)

        // No record carries a comment, so excluding by it keeps them all.
        #expect(try await store.query("purchase").exclude("comment", .equals, "gift").count() == 3)

        // Distance cannot be negated.
        await #expect(throws: SchemaError.invalidValue("product_id")) {
            _ = try await store.query("purchase")
                .exclude(.init(field: "product_id", op: .near, value: .location(latitude: 0, longitude: 0), radius: 10))
                .all()
        }
    }

    @Test("A compound alternative requires all of its filters at once")
    func compoundAlternative() async throws {
        // quantities: p-0 → 3, p-1 → 1, p-2 → 2
        let records = try await store.query("purchase")
            .group {
                $0.filter("product_id", .equals, "sku-1")
                $0.all("quantity" > 1, "quantity" < 3)
            }
            .sort("date")
            .all()
        #expect(records.map(\.uuid) == ["p-1", "p-2"])

        // The compound alternative distributes into the other operations too.
        let count = try await store.query("purchase")
            .group {
                $0.all("quantity" > 1, "amount" < 25)
            }
            .count()
        #expect(count == 1)
    }

    @Test("Builder update and delete honor OR groups")
    func groupMutation() async throws {
        try await store.query("purchase")
            .group {
                $0.filter("product_id", .equals, "sku-0")
                $0.filter("product_id", .equals, "sku-2")
            }
            .update { record in
                record.values["quantity"] = .int(9)
            }
        #expect(try await store.query("purchase").filter("quantity", .equals, 9).count() == 2)

        try await store.query("purchase")
            .group {
                $0.filter("product_id", .equals, "sku-0")
                $0.filter("product_id", .equals, "sku-2")
            }
            .delete()
        let remaining = try await store.query("purchase").all()
        #expect(remaining.map(\.uuid) == ["p-1"])
    }

    @Test("Folds compute over a single projected field")
    func folds() async throws {
        #expect(try await store.query("purchase").sum("quantity") == 6)
        #expect(try await store.query("purchase").filter("quantity" > 1).sum("amount") == 50)
        #expect(try await store.query("purchase").minimum("quantity") == 1)
        #expect(try await store.query("purchase").maximum("amount") == 30)
        #expect(try await store.query("purchase").average("quantity") == 2)
        #expect(try await store.query("purchase").filter("quantity" > 9).average("quantity") == nil)
        #expect(try await store.query("purchase").filter("quantity" > 9).sum("quantity") == 0)

        let grouped = try await store.query("purchase")
            .group {
                $0.filter("product_id", .equals, "sku-0")
                $0.filter("product_id", .equals, "sku-2")
            }
            .sum("quantity")
        #expect(grouped == 5)

        await #expect(throws: SchemaError.invalidValue("product_id")) {
            _ = try await store.query("purchase").sum("product_id")
        }
    }

    @Test("Grouped folds bucket by the grouping field's value")
    func groupedFolds() async throws {
        try await store.write(
            [
                "product_id": .string("sku-0"),
                "quantity": .int(5),
                "amount": .double(50),
                "date": .date(Date(timeIntervalSince1970: 4_000)),
            ], entity: "purchase", uuid: "p-3")

        #expect(try await store.query("purchase").sum("quantity", by: "product_id") == ["sku-0": 8, "sku-1": 1, "sku-2": 2])
        #expect(try await store.query("purchase").count(by: "product_id") == ["sku-0": 2, "sku-1": 1, "sku-2": 1])
        #expect(try await store.query("purchase").maximum("amount", by: "product_id") == ["sku-0": 50, "sku-1": 10, "sku-2": 20])
        #expect(try await store.query("purchase").filter("quantity" > 1).average("amount", by: "product_id") == ["sku-0": 40, "sku-2": 20])

        await #expect(throws: SchemaError.invalidValue("product_id")) {
            _ = try await store.query("purchase").sum("product_id", by: "quantity")
        }
        await #expect(throws: SchemaError.unknownField("ghost")) {
            _ = try await store.query("purchase").count(by: "ghost")
        }
    }

    @Test("Pagination and streaming honor OR groups")
    func groupPagination() async throws {
        func query() -> QueryBuilder {
            store.query("purchase").group {
                $0.filter("product_id", .equals, "sku-0")
                $0.filter("product_id", .equals, "sku-2")
            }
        }

        let first = try await query().paginate(size: 1)
        #expect(first.records.map(\.uuid) == ["p-0"])
        let cursor = try #require(first.cursor)

        let second = try await query().paginate(size: 1, after: cursor)
        #expect(second.records.map(\.uuid) == ["p-2"])

        var streamed: [String] = []
        for try await record in query().stream(pageSize: 1) {
            streamed.append(record.uuid)
        }
        #expect(streamed == ["p-0", "p-2"])
    }

    @Test("The builder pages by its sort clause, honoring OR groups")
    func fieldPage() async throws {
        // quantities: p-0 → 3, p-1 → 1, p-2 → 2
        let first = try await store.query("purchase").sort("quantity").page(size: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let second = try await store.query("purchase").sort("quantity").page(size: 2, after: try #require(first.cursor))
        #expect(second.records.map(\.uuid) == ["p-0"])
        #expect(second.cursor == nil)

        func grouped() -> QueryBuilder {
            store.query("purchase")
                .group {
                    $0.filter("product_id", .equals, "sku-0")
                    $0.filter("product_id", .equals, "sku-1")
                }
                .sort("quantity", .descending)
        }
        let top = try await grouped().page(size: 1)
        #expect(top.records.map(\.uuid) == ["p-0"])
        let rest = try await grouped().page(size: 1, after: try #require(top.cursor))
        #expect(rest.records.map(\.uuid) == ["p-1"])

        await #expect(throws: SchemaError.self) {
            _ = try await store.query("purchase").page(size: 1)
        }
    }

    @Test("Pagination with a sort clause throws instead of ignoring it")
    func paginateSortThrows() async throws {
        await #expect(throws: SchemaError.self) {
            _ = try await store.query("purchase").sort("quantity").paginate(size: 2)
        }
    }

    @Test("A record matching several OR branches is transformed once")
    func overlappingBranches() async throws {
        try await store.query("purchase")
            .group {
                $0.filter("quantity" > 1)
                $0.filter("product_id", .equals, "sku-0")
            }
            .update { record in
                guard case .int(let quantity)? = record.values["quantity"] else { return }
                record.values["quantity"] = .int(quantity + 1)
            }
        let records = try await store.query("purchase").sort("date").all()
        #expect(records.map { $0.values["quantity"] } == [.int(4), .int(1), .int(3)])
    }

    @Test("The schema builder's matches constraint lands in the definition")
    func matchesConstraint() async throws {
        try await store.schema("account")
            .field("email", .string, .matches("[^@]+@[^@]+"))
            .create()

        #expect(try await registry.definition(for: "account").field(named: "email", at: 1)?.pattern == "[^@]+@[^@]+")
        await #expect(throws: SchemaError.invalidValue("email")) {
            try await store.write(["email": .string("nope")], entity: "account", uuid: "a-1")
        }
    }

    @Test("Typed queries filter, sort, and decode through key paths")
    func typedQueries() async throws {
        let cheap = try await store.query(TypedPurchase.self)
            .filter(\.quantity > 1)
            .sort(\.quantity)
            .all()
        #expect(cheap.map(\.quantity) == [2, 3])
        #expect(cheap.map(\.productId) == ["sku-2", "sku-0"])

        let rest = try await store.query(TypedPurchase.self)
            .exclude(\.productId == "sku-0")
            .sort(\.amount, .descending)
            .first()
        #expect(rest?.productId == "sku-2")
        #expect(try await store.query(TypedPurchase.self).filter(\.amount <= 20).count() == 2)

        // A key path outside the field map fails loudly instead of matching nothing.
        await #expect(throws: SchemaError.self) {
            _ = try await store.query(TypedPurchase.self).filter(\.untracked == "x").all()
        }
    }

    @Test("Typed queries paginate, stream, observe, and scope by creator")
    func typedParity() async throws {
        // Envelope-date pages decode into structs and chain by cursor.
        let first = try await store.query(TypedPurchase.self).paginate(size: 2)
        #expect(first.items.map(\.productId) == ["sku-0", "sku-1"])
        let rest = try await store.query(TypedPurchase.self).paginate(size: 2, after: first.cursor)
        #expect(rest.items.map(\.productId) == ["sku-2"])
        #expect(rest.cursor == nil)

        // Field-ordered pages honor the single sort clause.
        let cheap = try await store.query(TypedPurchase.self).sort(\.amount).page(size: 2)
        #expect(cheap.items.map(\.amount) == [10, 20])
        let expensive = try await store.query(TypedPurchase.self).sort(\.amount).page(size: 2, after: cheap.cursor)
        #expect(expensive.items.map(\.amount) == [30])
        #expect(expensive.cursor == nil)

        // Streaming decodes every match, page by page.
        var streamed: [TypedPurchase] = []
        for try await purchase in try store.query(TypedPurchase.self).filter(\.quantity > 1).stream(pageSize: 1) {
            streamed.append(purchase)
        }
        #expect(Set(streamed.compactMap(\.productId)) == ["sku-0", "sku-2"])

        // observe: the first element is the current result, a write ticks a fresh one.
        var updates = try store.query(TypedPurchase.self).filter(\.quantity > 2).observe().makeAsyncIterator()
        #expect(try await updates.next()?.count == 1)
        try await store.write(
            ["product_id": .string("sku-9"), "quantity": .int(5), "date": .date(Date(timeIntervalSince1970: 9_000))],
            entity: "purchase", uuid: "p-9")
        #expect(try await updates.next()?.count == 2)

        // createdBy narrows to one user's records, decoded like any other read.
        database.records.first { $0.recordID.recordName == "p-0" }?.overrideCreator("user-a")
        let mine = try await store.query(TypedPurchase.self).createdBy("user-a").all()
        #expect(mine.map(\.productId) == ["sku-0"])
    }

    @Test("Zone deltas decode into typed items and typed tombstones")
    func typedDeltas() async throws {
        let zone = CKRecordZone.ID(zoneName: "typed-delta", ownerName: CKCurrentUserDefaultName)
        let zoned = EntityStore(database: database, registry: registry, zoneID: zone)
        try await zoned.ensureZone()
        try await zoned.schema("note").field("title", .string).create()

        try await zoned.write(["product_id": .string("sku-9"), "quantity": .int(4)], entity: "purchase", uuid: "tp-1")
        try await zoned.write(["title": .string("hi")], entity: "note", uuid: "n-1")
        try await zoned.write(["product_id": .string("sku-8"), "quantity": .int(2)], entity: "purchase", uuid: "tp-2")
        try await zoned.delete(entity: "purchase", uuid: "tp-2")

        // items decodes only the entity's live records; the note and the
        // tombstone stay out, and the tombstone surfaces as a typed deletion.
        let delta = try await zoned.zoneChanges()
        let purchases = delta.items(TypedPurchase.self)
        #expect(purchases.map(\.productId) == ["sku-9"])
        #expect(purchases.first?.quantity == 4)
        #expect(delta.deletedIDs(of: TypedPurchase.self) == ["tp-2"])
    }

    @Test("Unique keys reject duplicates without deriving identity")
    func uniqueKeys() async throws {
        try await store.schema("account")
            .field("email", .string, .required)
            .field("username", .string)
            .field("plan", .string)
            .uniqueKey(on: "email")
            .uniqueKey(on: "username")
            .create()

        try await store.write(["email": .string("a@x.io"), "username": .string("ann"), "plan": .string("free")], entity: "account", uuid: "u-1")

        // Each key constrains independently.
        await #expect(throws: SchemaError.duplicateKey(fields: ["email"])) {
            try await store.write(["email": .string("a@x.io"), "username": .string("bob")], entity: "account", uuid: "u-2")
        }
        await #expect(throws: SchemaError.duplicateKey(fields: ["username"])) {
            try await store.write(["email": .string("b@x.io"), "username": .string("ann")], entity: "account", uuid: "u-2")
        }

        // Distinct values pass, and a record missing a key field is exempt.
        try await store.write(["email": .string("b@x.io")], entity: "account", uuid: "u-2")
        try await store.write(["email": .string("c@x.io")], entity: "account", uuid: "u-3")

        // Rewriting a record with its own values does not trip its keys.
        try await store.write(["email": .string("a@x.io"), "username": .string("ann"), "plan": .string("pro")], entity: "account", uuid: "u-1")

        // An update stealing a taken value is rejected; a tombstoned record
        // frees its keys.
        await #expect(throws: SchemaError.duplicateKey(fields: ["email"])) {
            try await store.update(entity: "account", uuid: "u-2") { $0.values["email"] = .string("a@x.io") }
        }
        try await store.delete(entity: "account", uuid: "u-1")
        try await store.update(entity: "account", uuid: "u-2") { record in
            record.values["email"] = .string("a@x.io")
        }

        // In-batch duplicates are rejected before anything lands.
        await #expect(throws: SchemaError.duplicateKey(fields: ["email"])) {
            try await store.write(
                [EntityWrite(values: ["email": .string("d@x.io")], uuid: "u-4"), EntityWrite(values: ["email": .string("d@x.io")], uuid: "u-5")],
                entity: "account")
        }
    }

    @Test("A composite unique key constrains the tuple, not each field")
    func compositeUniqueKey() async throws {
        try await store.schema("membership")
            .field("group_id", .string, .required)
            .field("member", .string, .required)
            .uniqueKey(on: "group_id", "member")
            .create()

        try await store.write(["group_id": .string("g1"), "member": .string("m1")], entity: "membership", uuid: "m-1")
        try await store.write(["group_id": .string("g1"), "member": .string("m2")], entity: "membership", uuid: "m-2")
        try await store.write(["group_id": .string("g2"), "member": .string("m1")], entity: "membership", uuid: "m-3")
        await #expect(throws: SchemaError.duplicateKey(fields: ["group_id", "member"])) {
            try await store.write(["group_id": .string("g1"), "member": .string("m1")], entity: "membership", uuid: "m-4")
        }

        // An unknown key field fails schema validation up front.
        await #expect(throws: SchemaError.self) {
            try await store.schema("broken").field("name", .string).uniqueKey(on: "missing").create()
        }
    }

    @Test("Schema update keeps slots, closes removed fields, allocates new ones")
    func schemaUpdate() async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("quantity", .double)
            .field("date", .timestamp)
            .field("total", .double)
            .update()

        let definition = try await registry.definition(for: "purchase")
        #expect(definition.version == 2)
        #expect(definition.fields.first { $0.name == "product_id" }?.storage == .slot(.string, "s_00"))

        let quantities = definition.fields.filter { $0.name == "quantity" }
        #expect(quantities.contains { $0.storage == .slot(.int, "i_00") && $0.until == 2 })
        #expect(quantities.contains { $0.storage == .slot(.double, "d_01") && $0.since == 2 })

        let amount = try #require(definition.fields.first { $0.name == "amount" })
        #expect(amount.until == 2)

        let total = try #require(definition.fields.first { $0.name == "total" })
        #expect(total.since == 2)
        #expect(total.storage == .slot(.double, "d_02"))
    }

    @Test("Migrations run in order and are repeatable")
    func migrations() async throws {
        struct CreateNote: Migration {
            func prepare(on store: EntityStore) async throws {
                try await store.schema("note")
                    .field("title", .string)
                    .create()
            }
        }
        try await store.migrate([CreateNote()])
        try await store.migrate([CreateNote()])

        try await store.write(["title": .string("hi")], entity: "note", uuid: "n-1")
        #expect(try await store.query("note").count() == 1)
    }
}

// The shape scoutdb-codegen emits, written by hand for the typed-query tests;
// `untracked` deliberately stays out of the field map.
private struct TypedPurchase: EntityRepresentable {
    static let entityName = "purchase"

    static func fieldName(for keyPath: PartialKeyPath<TypedPurchase>) -> String? {
        switch keyPath {
        case \TypedPurchase.productId: "product_id"
        case \TypedPurchase.quantity: "quantity"
        case \TypedPurchase.amount: "amount"
        default: nil
        }
    }

    var productId: String?
    var quantity: Int64?
    var amount: Double?
    var untracked: String?

    init(record: EntityRecord) {
        productId = record["product_id"]
        quantity = record["quantity"]
        amount = record["amount"]
    }

    var recordValues: [String: RecordValue] {
        var values: [String: RecordValue] = [:]
        values["product_id"] = productId?.recordValue
        values["quantity"] = quantity?.recordValue
        values["amount"] = amount?.recordValue
        return values
    }
}
