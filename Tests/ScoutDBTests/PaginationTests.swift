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

        var (batch, cursor) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: 2)
        #expect(batch.map(\.0.recordName) == ["i-0", "i-1"])

        var names = batch.map(\.0.recordName)
        var pages = 1
        while let token = cursor {
            (batch, cursor) = try await database.records(continuingMatchFrom: token, desiredKeys: nil, resultsLimit: 2)
            names += batch.map(\.0.recordName)
            pages += 1
        }
        #expect(names == ["i-0", "i-1", "i-2", "i-3", "i-4"])
        #expect(pages == 3)
    }

    @Test("Continuation pages keep the projection")
    func projectionAcrossPages() async throws {
        let database = makeItemDatabase(count: 4)
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))

        let (_, cursor) = try await database.records(matching: query, desiredKeys: ["name"], resultsLimit: 2)
        let token = try #require(cursor)
        let (batch, _) = try await database.records(continuingMatchFrom: token, desiredKeys: ["name"], resultsLimit: 2)

        let record = try #require(try batch.first?.1.get())
        #expect(record["name"] as? String == "n-2")
        #expect(record["rank"] == nil)
    }

    @Test("A queued error surfaces from a continuation read")
    func continuationError() async throws {
        let database = makeItemDatabase(count: 4)
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))

        let (_, cursor) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: 2)
        let token = try #require(cursor)
        database.errors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await database.records(continuingMatchFrom: token, desiredKeys: nil, resultsLimit: 2)
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

        // `contains` on a payload field is a client-side matcher, so each 2-record server
        // page yields one survivor and the bounded read has to follow the cursor.
        let filter = EntityStore.Filter(field: "comment", op: .contains, value: .string("gif"))
        let records = try await store.read(entity: "purchase", filters: [filter], sort: [EntityStore.Sort(field: "date")], limit: 2)
        #expect(records.map(\.uuid) == ["p-0", "p-2"])
    }

    @Test("Keyset pages assemble from multiple server pages")
    func keysetAcrossServerPages() async throws {
        try await writePurchases(5)
        database.pageLimit = 2

        let first = try await store.read(entity: "purchase", limit: 3)
        #expect(first.records.map(\.uuid) == ["p-0", "p-1", "p-2"])
        let cursor = try #require(first.cursor)

        let second = try await store.read(entity: "purchase", limit: 3, after: cursor)
        #expect(second.records.map(\.uuid) == ["p-3", "p-4"])
        #expect(second.cursor == nil)
    }

    @Test("Stream pages through small server pages in order")
    func streamAcrossServerPages() async throws {
        try await writePurchases(5)
        database.pageLimit = 2

        var uuids: [String] = []
        for try await record in store.stream(entity: "purchase", pageSize: 3) {
            uuids.append(record.uuid)
        }
        #expect(uuids == ["p-0", "p-1", "p-2", "p-3", "p-4"])
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
