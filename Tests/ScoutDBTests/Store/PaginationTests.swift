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

@Suite("Pagination")
struct PaginationTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("The database serves resultsLimit records per page and a cursor for the rest")
    func databasePaging() async throws {
        let database = makeItemDatabase(count: 5)
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]

        var (batch, cursor) = try await database.records(matching: query, resultsLimit: 2)
        #expect(batch.map(\.0.recordName) == ["i-0", "i-1"])

        var names = batch.map(\.0.recordName)
        var pages = 1
        while let token = cursor {
            (batch, cursor) = try await database.records(continuingMatchFrom: token, resultsLimit: 2)
            names += batch.map(\.0.recordName)
            pages += 1
        }
        #expect(names == ["i-0", "i-1", "i-2", "i-3", "i-4"])
        #expect(pages == 3)
    }

    @Test("A continuation serves the matched order without re-running the query")
    func materializedContinuation() async throws {
        let database = makeItemDatabase(count: 6)
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]

        var (batch, cursor) = try await database.records(matching: query, resultsLimit: 2)
        #expect(batch.map(\.0.recordName) == ["i-0", "i-1"])

        database.records.removeAll { $0.recordID.recordName == "i-3" }
        let inserted = CKRecord(recordType: "Item", recordID: CKRecord.ID(recordName: "i-9"))
        inserted["rank"] = -1
        database.records.append(inserted)

        var names = batch.map(\.0.recordName)
        while let token = cursor {
            (batch, cursor) = try await database.records(continuingMatchFrom: token, resultsLimit: 2)
            names += batch.map(\.0.recordName)
        }
        #expect(names == ["i-0", "i-1", "i-2", "i-4", "i-5"])
    }

    @Test("A queued error surfaces from a continuation read")
    func continuationError() async throws {
        let database = makeItemDatabase(count: 4)
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))

        let (_, cursor) = try await database.records(matching: query, resultsLimit: 2)
        let token = try #require(cursor)
        database.errors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await database.records(continuingMatchFrom: token, resultsLimit: 2)
        }
    }

    @Test("An unlimited read follows the cursor across server pages")
    func allRecordsAcrossPages() async throws {
        try await writePurchases(5)
        database.pageLimit = 2

        let records = try await store.read(entity: "purchase")
        #expect(records.map(\.uuid).sorted() == ["p-0", "p-1", "p-2", "p-3", "p-4"])
    }

    @Test("A limited read keeps following the cursor until enough rows survive the client filter")
    func boundedReadAcrossPages() async throws {
        for index in 0..<6 {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            values["comment"] = .string(index % 2 == 0 ? "gift" : "other")
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }

        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        let records = try await store.read(
            entity: "purchase",
            filters: [filter],
            sort: [EntityStore.Sort(field: "date")],
            limit: 2
        )
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("A field-ordered page carries the ordering field and its cursor")
    func fieldPageCursor() async throws {
        try await writePurchases(3)

        let filters = [EntityStore.Filter(field: "product_id", op: .equals, value: .string("sku-42"))]
        let page = try await store.read(entity: "purchase", any: [filters], orderedBy: "quantity", limit: 2)
        #expect(page.records.count == 2)
        #expect(page.records.allSatisfy { $0.values["quantity"] != nil })
        #expect(try #require(page.cursor).value == page.records.last?.values["quantity"])
    }

    @Test("A field-ordered walk over records sharing one value serves every one of them")
    func tiedFieldValuesArePagedWhole() async throws {
        for index in (0..<25).reversed() {
            var values = makePurchase().values
            values["quantity"] = .int(7)
            try await store.write(values, entity: "purchase", uuid: String(format: "q-%02d", index))
        }

        var served: [String] = []
        var cursor: FieldCursor?
        repeat {
            let page = try await store.read(entity: "purchase", orderedBy: "quantity", limit: 10, after: cursor)
            served += page.records.map(\.uuid)
            cursor = page.cursor
        } while cursor != nil

        #expect(Set(served).count == 25)
    }

    private func makeItemDatabase(count: Int) -> InMemoryDatabase {
        let database = InMemoryDatabase()
        for index in 0..<count {
            let record = CKRecord(recordType: "Item", recordID: CKRecord.ID(recordName: "i-\(index)"))
            record["rank"] = index
            record["name"] = "n-\(index)"
            database.records.append(record)
        }
        return database
    }

    private func writePurchases(_ count: Int) async throws {
        for index in 0..<count {
            var values = makePurchase().values
            values["date"] = .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
            try await store.write(values, entity: "purchase", uuid: "p-\(index)")
        }
    }
}
