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

    @Test("A fetch by uuid reads a record the query index has not caught up with")
    func fetchByUUIDSkipsTheIndex() async throws {
        try await store.write([EntityWrite(values: makePurchase().values, uuid: "p-1")], entity: "purchase")
        database.unindexed = [CKRecord.ID(recordName: "p-1", zoneID: .default)]

        #expect(try await ReadOperation(store: store, entity: "purchase").records().isEmpty)
        #expect(try await store.fetch(uuid: "p-1")?.uuid == "p-1")
        #expect(try await store.fetch(uuid: "p-9") == nil)
    }

    @Test("Keyset pagination walks records in date order")
    func pagination() async throws {
        for (index, seconds) in [3_000, 1_000, 2_000].enumerated() {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }

        let first = try await store.query("purchase").sort("date").page(size: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let cursor = try #require(first.cursor)

        let second = try await store.query("purchase").sort("date").page(size: 2, after: cursor)
        #expect(second.records.map(\.uuid) == ["p-0"])
        #expect(second.cursor == nil)
    }

    @Test("Keyset pagination orders by an arbitrary field in both directions")
    func fieldPagination() async throws {
        for (index, quantity) in [3, 1, 2, 2].enumerated() {
            var values = makePurchase().values
            values["quantity"] = .int(Int64(quantity))
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }

        let first = try await store.query("purchase").sort("quantity").page(size: 2)
        #expect(first.records.map(\.uuid) == ["p-1", "p-2"])
        let firstCursor = try #require(first.cursor)
        let second = try await store.query("purchase").sort("quantity").page(size: 2, after: firstCursor)
        #expect(second.records.map(\.uuid) == ["p-3", "p-0"])

        let top = try await store.query("purchase").sort("quantity", .reverse).page(size: 3)
        #expect(top.records.map(\.uuid) == ["p-0", "p-2", "p-3"])
        let topCursor = try #require(top.cursor)
        let rest = try await store.query("purchase").sort("quantity", .reverse).page(size: 3, after: topCursor)
        #expect(rest.records.map(\.uuid) == ["p-1"])
        #expect(rest.cursor == nil)

        await #expect(throws: SchemaError.unsupportedQuery(.unpageableField("comment"))) {
            _ = try await store.query("purchase").sort("comment").page(size: 1)
        }
    }

    @Test("Sorting by a payload field ranks client-side")
    func payloadSort() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "player",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_01")),
                    FieldDefinition(name: "score", type: .int, storage: .payload("p_00")),
                ]
            )
        )
        try await store.write(
            [EntityWrite(values: ["name": .string("Ada"), "score": .int(10)], uuid: "u-1")], entity: "player")
        try await store.write(
            [EntityWrite(values: ["name": .string("Bo"), "score": .int(5)], uuid: "u-2")], entity: "player")
        try await store.write([EntityWrite(values: ["name": .string("Cy")], uuid: "u-3")], entity: "player")

        let ranked = try await ReadOperation(store: store, entity: "player", sort: [.init(field: "score")]).records()
        #expect(ranked.map(\.uuid) == ["u-3", "u-2", "u-1"])

        let top = try await ReadOperation(
            store: store, entity: "player", sort: [.init(field: "score", order: .reverse)]
        )
        .records(limit: 2)
        #expect(top.map(\.uuid) == ["u-1", "u-2"])
        #expect(try await store.query("player").sort("score", .reverse).first()?.uuid == "u-1")

        await #expect(throws: SchemaError.unknownField("ghost")) {
            _ = try await ReadOperation(store: store, entity: "player", sort: [.init(field: "ghost")]).records()
        }
    }

    @Test("A sort the server cannot serve is refused on one alternative as on many")
    func unsortableAcrossAlternatives() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "doc",
                fields: [
                    FieldDefinition(name: "kind", type: .string, storage: .slot(.string, "s_01")),
                    FieldDefinition(name: "blob", type: .bytes, storage: .slot(.bytes, "b_00")),
                ]
            )
        )
        for index in 0..<8 {
            try await store.write(
                [
                    EntityWrite(
                        values: [
                            "kind": .string(index.isMultiple(of: 2) ? "a" : "b"),
                            "blob": .bytes(Data([UInt8(index)])),
                        ],
                        uuid: "d-\(index)"
                    )
                ],
                entity: "doc"
            )
        }

        let refusal = SchemaError.unsupportedQuery(.unsortableField("blob"))

        await #expect(throws: refusal) {
            try await store.query("doc").filter("kind" == "a").sort("blob").take(2)
        }
        await #expect(throws: refusal) {
            try await store.query("doc").filter("kind" == "a" || "kind" == "b" && "blob" == .bytes(Data([1])))
                .sort("blob")
                .take(2)
        }
    }

    @Test("Filters on payload fields fall back to client-side matching")
    func payloadFilters() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_01")),
                    FieldDefinition(name: "score", type: .int, storage: .payload("p_00")),
                    FieldDefinition(name: "tags", type: .stringList, storage: .payload("p_01")),
                ]
            )
        )
        try await store.write(
            [
                EntityWrite(
                    values: ["name": .string("Ada"), "score": .int(10), "tags": .strings(["swift", "db"])], uuid: "u-1")
            ], entity: "profile")
        try await store.write(
            [EntityWrite(values: ["name": .string("Bo"), "score": .int(5), "tags": .strings(["db"])], uuid: "u-2")],
            entity: "profile")
        try await store.write([EntityWrite(values: ["name": .string("Cy")], uuid: "u-3")], entity: "profile")

        func uuids(_ filters: [ClientFilter]) async throws -> [String] {
            try await ReadOperation(store: store, entity: "profile", branches: [filters]).records().map(\.uuid).sorted()
        }

        #expect(try await uuids([.init(field: "score", op: .equals, value: .int(10))]) == ["u-1"])
        #expect(try await uuids([.init(field: "score", op: .greaterThan, value: .int(4))]) == ["u-1", "u-2"])
        #expect(try await uuids([.init(field: "score", op: .lessThanOrEquals, value: .int(5))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .in, value: .ints([5, 7]))]) == ["u-2"])
        #expect(try await uuids([.init(field: "tags", op: .contains, value: .string("swift"))]) == ["u-1"])
        #expect(try await uuids([.init(field: "score", op: .notEquals, value: .int(10))]) == ["u-2"])
        #expect(try await uuids([.init(field: "score", op: .notIn, value: .ints([10]))]) == ["u-2"])
    }

    @Test("A batch naming one uuid twice writes one record and answers one uuid")
    func duplicateUUIDInBatch() async throws {
        var first = makePurchase().values
        first["product_id"] = .string("sku-first")
        var second = makePurchase().values
        second["product_id"] = .string("sku-second")

        database.resetRequests()
        let uuids = try await store.write(
            [EntityWrite(values: first, uuid: "p-1"), EntityWrite(values: second, uuid: "p-1")],
            entity: "purchase"
        )

        #expect(uuids == ["p-1"])
        #expect(database.requests[.modify] == 1)
        #expect(try await store.fetch(uuid: "p-1")?.values["product_id"] == .string("sku-second"))
        #expect(try await ReadOperation(store: store, entity: "purchase").records().count == 1)
    }

    @Test("A batch write surfaces the error the database raised")
    func batchWriteError() async throws {
        database.writeErrors = [CKError(.partialFailure)]

        do {
            try await store.write([EntityWrite(values: makePurchase().values, uuid: "p-1")], entity: "purchase")
            Issue.record("Expected a CKError")
        } catch let error as CKError {
            #expect(error.code == .partialFailure)
        }
    }

    @Test("A write claims a uuid nothing had written yet")
    func writeClaimsUnwritten() async throws {
        #expect(try await store.fetch(entity: "purchase", uuids: ["t-1"]).isEmpty)

        try await store.write([EntityWrite(values: makePurchase().values, uuid: "t-1")], entity: "purchase")
        #expect(try await ReadOperation(store: store, entity: "purchase").records().map(\.uuid) == ["t-1"])
    }

    @Test("A pattern constraint gates writes by a whole-string regex")
    func patternValidation() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "account",
                fields: [
                    FieldDefinition(
                        name: "email",
                        type: .string,
                        storage: .slot(.string, "s_01"),
                        pattern: "[^@]+@[^@]+\\.[a-z]+"
                    ),
                    FieldDefinition(
                        name: "codes",
                        type: .stringList,
                        storage: .slot(.stringList, "ls_00"),
                        pattern: "[A-Z]{3}"
                    ),
                ]
            )
        )

        try await store.write(
            [
                EntityWrite(
                    values: ["email": .string("ada@example.com"), "codes": .strings(["ABC", "XYZ"])], uuid: "a-1")
            ], entity: "account")

        await #expect(throws: SchemaError.invalidValue(.patternMismatch(field: "email"))) {
            try await store.write(
                [EntityWrite(values: ["email": .string("not-an-email")], uuid: "a-2")], entity: "account")
        }
        await #expect(throws: SchemaError.invalidValue(.patternMismatch(field: "codes"))) {
            try await store.write(
                [
                    EntityWrite(
                        values: ["email": .string("bo@example.com"), "codes": .strings(["ABC", "nope"])], uuid: "a-3")
                ], entity: "account")
        }
        await #expect(throws: SchemaError.invalidValue(.patternMismatch(field: "email"))) {
            try await store.write(
                [EntityWrite(values: ["email": .string("ada@example.com !!")], uuid: "a-4")], entity: "account")
        }

        let numeric = makeDefinition(fields: [
            FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_01"), pattern: "[0-9]+")
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.unsupportedPattern(field: "count", type: .int))) {
            try numeric.validate()
        }
        let broken = makeDefinition(fields: [
            FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_01"), pattern: "([")
        ]
        )
        #expect(throws: SchemaError.invalidDefinition(.malformedPattern(field: "email"))) { try broken.validate() }
    }

    @Test("Fetch by identifier resolves the entity from the record")
    func fetchByUUID() async throws {
        try await store.write([EntityWrite(values: makePurchase().values, uuid: "p-1")], entity: "purchase")

        let record = try await store.fetch(uuid: "p-1")

        #expect(record?.entity == "purchase")
        #expect(record?.values["quantity"] == makePurchase().values["quantity"])
        #expect(try await store.fetch(uuid: "ghost") == nil)
    }

    @Test("Fetching by uuid stays scoped to the asked-for entity")
    func fetchStaysScopedToEntity() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "ticket",
                fields: [
                    FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_01"))
                ]
            )
        )

        try await store.write([EntityWrite(values: makePurchase().values, uuid: "shared")], entity: "purchase")
        try await store.write([EntityWrite(values: ["label": .string("t")], uuid: "shared")], entity: "ticket")

        #expect(try await store.fetch(entity: "purchase", uuids: ["shared"]).isEmpty)
        #expect(try await store.fetch(entity: "ticket", uuids: ["shared"]).map(\.uuid) == ["shared"])
    }

    @Test("A query splits into server predicates, client matchers and slot sorts")
    func queryPlanning() async throws {
        let filters = [
            ClientFilter(field: "product_id", op: .equals, value: .string("sku-42")),
            ClientFilter(field: "comment", op: .contains, value: .string("gif")),
        ]
        let definition = try await registry.definition(for: "purchase")
        let server = try definition.serverFilters(filters)
        let client = try definition.clientFilters(filters)
        #expect(server.contains(CKQuery.Filter(field: "s_01", op: .equals, value: .string("sku-42"))))
        #expect(client == [filters[1]])
        #expect(
            try definition.serverSort([EntityStore.Sort(field: "date")]) == [
                CKQuery.Sort(field: "t_00", order: .forward)
            ]
        )
    }

    @Test("Paginated reads apply client-side filters across pages")
    func paginationWithClientFilter() async throws {
        for index in 0..<4 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            values["comment"] = .string(index % 2 == 0 ? "gift" : "other")
            try await store.write([EntityWrite(values: values, uuid: "p-\(index)")], entity: "purchase")
        }

        var uuids: [String] = []
        var cursor: FieldCursor?
        repeat {
            let page = try await store.query("purchase")
                .filter("comment", .contains, "gif")
                .sort("date")
                .page(size: 1, after: cursor)
            uuids += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil
        #expect(uuids == ["p-0", "p-2"])
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
        let mismatched: [Int64]? = record["tags"]
        #expect(mismatched == nil)
    }
}
