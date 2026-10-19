//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Selection")
struct SelectionTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())

        for index in 0..<4 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            values["comment"] = .string(index % 2 == 0 ? "gift" : "other")
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }
    }

    @Test("A selection reads only the named fields, on the first page and on every continuation")
    func namedFieldsOnly() async throws {
        database.pageLimit = 1

        let records = try await store.query("purchase").select(["product_id"]).take(10)

        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.values == ["product_id": .string("sku-42")] })
    }

    @Test("A read without a selection keeps every field")
    func wholeRecords() async throws {
        let record = try #require(try await store.query("purchase").first())

        #expect(Set(record.values.keys) == ["product_id", "date", "quantity", "total", "comment"])
    }

    @Test("A client-side filter and a sort read their fields even when the selection leaves them out")
    func filterAndSortFields() async throws {
        let records = try await store.query("purchase")
            .filter("comment", .contains, "gif")
            .sort("date")
            .select(["product_id"])
            .take(10)

        #expect(records.map(\.uuid) == ["p-0", "p-2"])
        #expect(records.allSatisfy { Set($0.values.keys) == ["product_id", "comment", "date"] })
    }

    @Test("Keyset pagination walks a selection with the sort field kept for the cursor")
    func pagedSelection() async throws {
        var uuids: [String] = []
        var cursor: FieldCursor?

        repeat {
            let page = try await store.query("purchase")
                .sort("date", .reverse)
                .select(["product_id"])
                .page(size: 3, after: cursor)
            #expect(page.records.allSatisfy { Set($0.values.keys) == ["product_id", "date"] })
            uuids += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil

        #expect(uuids == ["p-3", "p-2", "p-1", "p-0"])
    }

    @Test("A payload sort ranks a selection on the client")
    func payloadSortSelection() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "player",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_02")),
                    FieldDefinition(name: "score", type: .int, storage: .payload("p_00")),
                ]
            )
        )
        for (uuid, name, score) in [("u-1", "Ada", 10), ("u-2", "Bo", 5), ("u-3", "Cy", 7)] {
            try await store.write(
                [EntityWrite(values: ["name": .string(name), "score": .int(Int64(score))], uuid: uuid)],
                entity: "player"
            )
        }

        let top = try await store.query("player").sort("score", .reverse).select(["name"]).take(2)

        #expect(top.map(\.uuid) == ["u-1", "u-3"])
    }

    @Test("An unknown field in a selection throws when the query runs")
    func unknownField() async throws {
        await #expect(throws: SchemaError.unknownField("ghost")) {
            _ = try await store.query("purchase").select(["ghost"]).take(1)
        }
    }

    @Test("A field declared again fetches every slot it ever held, with the envelope")
    func everySlotOfAField() throws {
        let definition = makeDefinition(
            entity: "ticket",
            fields: [
                FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_02"), until: 2),
                FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_03"), since: 2),
                FieldDefinition(name: "owner", type: .string, storage: .slot(.string, "s_04")),
            ]
        )

        #expect(try definition.keys(names: ["label"]) == ["i_00", "s_00", "s_01", "s_02", "s_03"])
    }
}
