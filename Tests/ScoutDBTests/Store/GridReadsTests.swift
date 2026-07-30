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

@Suite("Grid reads, asked for by shape")
struct GridReadsTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry
    let noon = Date(timeIntervalSince1970: 36_000)

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("payment")
            .field("product", .string, .required)
            .field("amount", .double)
            .field("date", .timestamp)
            .envelopeDate("date")
            .sum("amount", by: "product", bucket: .day)
            .histogram(of: "amount", bounds: [10, 20, 30])
            .create()

        for (product, amount) in [("app", 5.0), ("app", 15.0), ("pro", 25.0)] {
            try await store.write(["product": .string(product), "amount": .double(amount), "date": .date(noon)], entity: "payment")
        }
    }

    @Test("Totals come back for the grouping and metric asked for, no view named")
    func totalsByShape() async throws {
        let totals = try await store.query("payment").totals("amount", by: "product")
        #expect(totals.map(\.group) == ["app", "pro"])
        #expect(totals.first { $0.group == "app" }?.value == 20)
        #expect(totals.first { $0.group == "app" }?.count == 2)
    }

    @Test("Counting alone needs no metric field")
    func countingRows() async throws {
        let totals = try await store.query("payment").totals(by: "product")
        #expect(totals.map(\.group) == ["app", "pro"])
        #expect(totals.map(\.count) == [2, 1])
    }

    @Test("A series reads the same grid at cell resolution")
    func series() async throws {
        let points = try await store.query("payment").series("amount", by: "product")
        #expect(points.map(\.group) == ["app", "pro"])
        #expect(points.first { $0.group == "pro" }?.value == 25)
    }

    @Test("An equality filter on the grouping field narrows to that group")
    func filterNarrowsToOneGroup() async throws {
        let totals = try await store.query("payment").filter("product", .equals, .string("app")).totals("amount", by: "product")
        #expect(totals.map(\.group) == ["app"])
    }

    @Test("A filter the grid cannot honor throws instead of being dropped")
    func unhonorableFilterThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment").filter("amount" > 10).totals("amount", by: "product")
        }
    }

    @Test("A shape nothing grids says so")
    func missingShapeThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment").totals("amount", by: "missing")
        }
    }

    @Test("A percentile finds the histogram by its field")
    func percentileByField() async throws {
        #expect(try await store.query("payment").percentile(0.5, of: "amount") == 15)
    }

    @Test("The finest grid wins when the bucket is left out, and a named one is honored")
    func bucketPreference() async throws {
        try await store.schema("visit")
            .field("page", .string, .required)
            .field("date", .timestamp)
            .envelopeDate("date")
            .count(by: "page", bucket: .hour)
            .count(by: "page", bucket: .day)
            .create()

        let definition = try await registry.definition(for: "visit")
        #expect(definition.view(grouping: "page", folding: nil)?.bucket == .hour)
        #expect(definition.view(grouping: "page", folding: nil, bucket: .day)?.bucket == .day)
    }
}
