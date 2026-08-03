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

@Suite("Chained builders")
struct BuilderTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("quantity", .int, .min(0))
            .field("amount", .double)
            .field("date", .timestamp)
            .field("comment", .string, .payload)
            .create()

        for (index, quantity) in [3, 1, 2].enumerated() {
            try await store.write(
                [
                    EntityWrite(
                        values: [
                            "product_id": .string("sku-\(index)"), "quantity": .int(Int64(quantity)),
                            "amount": .double(Double(quantity) * 10),
                            "date": .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000))),
                        ], uuid: "p-\(index)")
                ], entity: "purchase")
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
        #expect(definition.fields.first { $0.name == "quantity" }?.min == 0)
    }

    @Test("Creation grids every groupable field")
    func implicitGrid() async throws {
        let definition = try await registry.definition(for: "purchase")
        let aggregates = try #require(definition.aggregates)
        #expect(Set(aggregates.map(\.name)) == ["by_product_id", "by_quantity", "by_amount"])
        #expect(aggregates.first { $0.name == "by_product_id" }?.groupBy == "product_id")

        let counted = try await TotalOperation(store: store, entity: "purchase").rows(aggregate: "by_product_id")
        #expect(counted.map(\.count).reduce(0, +) == 3)
        #expect(try await store.query("purchase").filter("product_id", .equals, "sku-1").count() == 1)
    }

    @Test("Creation leaves the fields it cannot group by out of the grid")
    func implicitGridWithoutDates() async throws {
        try await store.schema("label")
            .field("slug", .string, .required)
            .field("caption", .text)
            .field("aliases", .stringList)
            .create()

        let aggregates = try #require(try await registry.definition(for: "label").aggregates)
        #expect(aggregates.map(\.name) == ["by_slug"])
    }

    @Test("A declared metric keeps the grid from counting its field twice")
    func declaredViewWins() async throws {
        try await store.schema("shipment")
            .field("carrier", .string, .required)
            .field("weight", .double)
            .field("sent", .timestamp)
            .sum("weight", by: "carrier")
            .create()

        let aggregates = try #require(try await registry.definition(for: "shipment").aggregates)
        #expect(aggregates.filter { $0.groupBy == "carrier" }.count == 1)
        #expect(aggregates.first { $0.groupBy == "carrier" }?.sum == "weight")
        #expect(Set(aggregates.compactMap(\.groupBy)) == ["carrier", "weight"])
    }

    @Test("A declared extremum reaches the published grid")
    func declaredExtremum() async throws {
        try await store.schema("reading")
            .field("sensor", .string, .required)
            .field("value", .double)
            .min("value", by: "sensor")
            .max("value", by: "sensor")
            .create()

        let aggregates = try #require(try await registry.definition(for: "reading").aggregates)
        #expect(aggregates.first { $0.name == "min_value_by_sensor" }?.min == "value")
        #expect(aggregates.first { $0.name == "max_value_by_sensor" }?.max == "value")
    }

    @Test("An ungrouped field is left out of the grid")
    func ungroupedField() async throws {
        try await store.schema("event")
            .field("session", .string, .required, .ungrouped)
            .field("kind", .string, .required)
            .create()

        #expect(try await registry.definition(for: "event").aggregates?.compactMap(\.groupBy) == ["kind"])
    }

    @Test("An update inherits the grid instead of building its own")
    func updateKeepsTheGrid() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .create()
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("assignee", .string)
            .update()

        let updated = try await registry.definition(for: "ticket")
        #expect(updated.version == 2)
        #expect(updated.aggregates?.map(\.name) == ["by_queue"])
    }

    @Test("An update names the fields its new version leaves uncounted")
    func updateReportsMissingViews() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .create()

        let missing = try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("assignee", .string)
            .field("notes", .string, .payload)
            .update()

        #expect(missing == ["assignee"])
    }

    @Test("An update that adds no groupable field suggests nothing")
    func updateWithoutNewFieldsSuggestsNothing() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .create()

        let missing = try await store.schema("ticket")
            .field("queue", .string, .required)
            .update()

        #expect(missing.isEmpty)
    }

    @Test("An aggregate declared on an update joins the grid instead of replacing it")
    func declaredViewJoinsTheGrid() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .create()

        let missing = try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("assignee", .string)
            .count(by: "assignee")
            .update()

        #expect(missing.isEmpty)
        let updated = try await registry.definition(for: "ticket")
        #expect(updated.aggregates?.compactMap(\.groupBy) == ["queue", "assignee"])
    }

    @Test("An aggregate of the same shape replaces the one the grid built")
    func declaredViewOverridesTheGrid() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double)
            .create()

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double)
            .sum("weight", by: "queue")
            .update()

        let updated = try #require(try await registry.definition(for: "ticket").aggregates)
        #expect(Set(updated.compactMap(\.groupBy)) == ["queue", "weight"])
        #expect(updated.first { $0.groupBy == "queue" }?.sum == "weight")
    }

    @Test("An aggregate over a field the version closes lapses with it")
    func closedFieldDropsItsAggregate() async throws {
        try await store.schema("ticket")
            .field("queue", .string, .required)
            .field("weight", .double)
            .create()

        try await store.schema("ticket")
            .field("queue", .string, .required)
            .update()

        #expect(try await registry.definition(for: "ticket").aggregates?.compactMap(\.groupBy) == ["queue"])
    }

    @Test("Query builder filters, sorts, and limits")
    func query() async throws {
        let records = try await store.query("purchase")
            .filter("quantity" > 1)
            .sort("quantity", .reverse)
            .take(1)
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
        let record = try await store.query("purchase").sort("date", .reverse).first()
        #expect(record?.uuid == "p-2")
    }

    @Test("Equalities over one field fold into a single in-list branch")
    func disjunctionFolds() async throws {
        let builder = store.query("purchase")
            .filter("product_id" == "sku-0" || "product_id" == "sku-1" || "product_id" == "sku-2")
        #expect(builder.alternatives.count == 1)

        let definition = try await registry.definition(for: "purchase")
        let server = try definition.serverFilters(builder.alternatives[0])
        #expect(server.contains { $0.op == .in && $0.value == .strings(["sku-0", "sku-1", "sku-2"]) })
    }

    @Test("A conjunction inside a disjunction multiplies the alternatives out")
    func conjunctionDistributes() async throws {
        let builder = store.query("purchase")
            .filter(("quantity" > 1 || "quantity" < 0) && ("amount" > 5 || "amount" < 1))

        #expect(builder.alternatives.count == 4)
    }

    @Test("An expression narrows the same way a plain filter does")
    func expressionNarrows() async throws {
        let records = try await store.query("purchase")
            .filter("quantity" > 0)
            .filter("product_id" == "sku-0" || ("quantity" > 1 && "amount" < 25))
            .sort("date")
            .take(100)

        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("A disjunction distributes over the base filters")
    func orGroup() async throws {
        let records = try await store.query("purchase")
            .filter("quantity" > 0)
            .filter("product_id" == "sku-0" || "product_id" == "sku-2")
            .sort("date")
            .take(100)
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("A base filter rides along every alternative the query fans into")
    func baseFilterFansOut() async throws {
        let builder = store.query("purchase")
            .filter("quantity" > 0)
            .filter("product_id" == "sku-0" || "quantity" == 2)
        #expect(builder.alternatives.count == 2)

        let definition = try await registry.definition(for: "purchase")
        let branches = try builder.alternatives.map {
            try definition.serverFilters($0)
        }
        #expect(branches[0].contains { branches[1].contains($0) })
        #expect(branches.contains { $0.contains { $0.value == .string("sku-0") } })
    }

    @Test("A negative match drops the records the value matches")
    func negativeFilters() async throws {
        let records = try await store.query("purchase")
            .filter("product_id", .notEquals, "sku-1")
            .sort("date")
            .take(100)
        #expect(records.map(\.uuid) == ["p-0", "p-2"])

        #expect(
            try await store.query("purchase").filter("quantity" > 1).filter("quantity", .notEquals, 3).count() == 1
        )
        #expect(try await store.query("purchase").filter("product_id", .notIn, .strings(["sku-0"])).count() == 2)
    }

    @Test("A negative match over a slot-backed field runs on the server")
    func negativePushdown() async throws {
        func server(_ builder: QueryBuilder, using definition: EntityDefinition) throws -> [CKQuery.Filter] {
            try definition.serverFilters(builder.alternatives[0])
        }
        func client(_ builder: QueryBuilder, using definition: EntityDefinition) throws -> [ClientFilter] {
            try definition.clientFilters(builder.alternatives[0])
        }

        let purchase = try await registry.definition(for: "purchase")

        let slotted = store.query("purchase").filter("product_id", .notEquals, "sku-1")
        #expect(
            try server(slotted, using: purchase).contains(
                CKQuery.Filter(field: "s_00", op: .notEquals, value: .string("sku-1"))
            )
        )
        #expect(try client(slotted, using: purchase).isEmpty)

        let payload = store.query("purchase").filter("comment", .notEquals, "gift")
        #expect(
            try client(payload, using: purchase).contains(
                ClientFilter(field: "comment", op: .notEquals, value: .string("gift"))
            )
        )

        try await store.schema("shipment")
            .field("carrier", .string, .required)
            .field("weight", .double, .defaultValue(.double(0)))
            .create()
        let shipment = try await registry.definition(for: "shipment")

        let listed = store.query("shipment").filter("carrier", .notIn, .strings(["ups", "dhl"]))
        #expect(
            try server(listed, using: shipment).contains(
                CKQuery.Filter(field: "s_00", op: .notIn, value: .strings(["ups", "dhl"]))
            )
        )
    }

    @Test("A compound alternative requires all of its filters at once")
    func compoundAlternative() async throws {
        let records = try await store.query("purchase")
            .filter("product_id" == "sku-1" || ("quantity" > 1 && "quantity" < 3))
            .sort("date")
            .take(100)
        #expect(records.map(\.uuid) == ["p-1", "p-2"])

        let count = try await store.query("purchase")
            .filter("quantity" > 1 && "amount" < 25)
            .count()
        #expect(count == 1)
    }

    @Test("Folds compute over a single projected field")
    func folds() async throws {
        #expect(try await store.query("purchase").sum("quantity") == 6)
        #expect(try await store.query("purchase").filter("quantity" > 1).sum("amount") == 50)
        #expect(try await store.query("purchase").min("quantity") == 1)
        #expect(try await store.query("purchase").max("amount") == 30)
        #expect(try await store.query("purchase").average("quantity") == 2)
        #expect(try await store.query("purchase").filter("quantity" > 9).average("quantity") == nil)
        #expect(try await store.query("purchase").filter("quantity" > 9).sum("quantity") == 0)

        let grouped = try await store.query("purchase")
            .filter("product_id" == "sku-0" || "product_id" == "sku-2")
            .sum("quantity")
        #expect(grouped == 5)

        await #expect(throws: SchemaError.unsupportedQuery(.nonNumericField("product_id"))) {
            _ = try await store.query("purchase").sum("product_id")
        }
    }

    @Test("Grouped totals bucket by the grouping field's value")
    func groupedTotals() async throws {
        try await store.write(
            [
                EntityWrite(
                    values: [
                        "product_id": .string("sku-0"), "quantity": .int(5), "amount": .double(50),
                        "date": .date(Date(timeIntervalSince1970: 4_000)),
                    ], uuid: "p-3")
            ], entity: "purchase")

        let totals = try await store.query("purchase").totals(metric: .sum, group: "product_id")
        #expect(totals.map(\.group) == ["sku-0", "sku-1", "sku-2"])
        #expect(totals.map(\.count) == [2, 1, 1])
    }

    @Test("The builder pages by its sort clause, honoring OR groups")
    func fieldPage() async throws {
        let first = try await store.query("purchase").sort("quantity").page(size: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let firstCursor = try #require(first.cursor)
        let second = try await store.query("purchase").sort("quantity").page(size: 2, after: firstCursor)
        #expect(second.records.map(\.uuid) == ["p-0"])
        #expect(second.cursor == nil)

        func grouped() -> QueryBuilder {
            store.query("purchase")
                .filter("product_id" == "sku-0" || "product_id" == "sku-1")
                .sort("quantity", .reverse)
        }
        let top = try await grouped().page(size: 1)
        #expect(top.records.map(\.uuid) == ["p-0"])
        let topCursor = try #require(top.cursor)
        let rest = try await grouped().page(size: 1, after: topCursor)
        #expect(rest.records.map(\.uuid) == ["p-1"])

        await #expect(throws: SchemaError.self) {
            _ = try await store.query("purchase").page(size: 1)
        }
    }

    @Test("The schema builder's matches constraint lands in the definition")
    func matchesConstraint() async throws {
        try await store.schema("account")
            .field("email", .string, .matches("[^@]+@[^@]+"))
            .create()

        #expect(try await registry.definition(for: "account").field("email", at: 1).pattern == "[^@]+@[^@]+")
        await #expect(throws: SchemaError.invalidValue(.patternMismatch(field: "email"))) {
            try await store.write([EntityWrite(values: ["email": .string("nope")], uuid: "a-1")], entity: "account")
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

        try await store.write([EntityWrite(values: ["title": .string("hi")], uuid: "n-1")], entity: "note")
        #expect(try await store.query("note").count() == 1)
    }
}
