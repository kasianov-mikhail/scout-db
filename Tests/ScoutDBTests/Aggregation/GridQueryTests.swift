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

@Suite("Grid queries, asked for by shape")
struct GridQueryTests {
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
            .sum("amount", by: "product")
            .create()

        for (product, amount) in [("app", 5.0), ("app", 15.0), ("pro", 25.0)] {
            try await store.write(
                [
                    EntityWrite(
                        values: ["product": .string(product), "amount": .double(amount), "date": .date(noon)], uuid: nil
                    )
                ],
                entity: "payment")
        }
    }

    @Test("Totals come back for the grouping and metric asked for, no aggregate named")
    func totalsByShape() async throws {
        let totals = try await store.query("payment").totals("amount", metric: .sum, group: "product")
        #expect(totals.map(\.group) == ["app", "pro"])
        #expect(totals.first { $0.group == "app" }?.value == 20)
        #expect(totals.first { $0.group == "pro" }?.value == 25)
    }

    @Test("Counting alone needs no metric field")
    func countingRows() async throws {
        let totals = try await store.query("payment").totals(metric: .sum, group: "product")
        #expect(totals.map(\.group) == ["app", "pro"])
        #expect(totals.map(\.value) == [2, 1])
    }

    @Test("An equality filter on the grouping field narrows to that group")
    func filterNarrowsToOneGroup() async throws {
        let totals = try await store.query("payment").filter("product", .equals, .string("app")).totals(
            "amount", metric: .sum, group: "product")
        #expect(totals.map(\.group) == ["app"])
    }

    @Test("A filter the grid cannot honor throws instead of being dropped")
    func unhonorableFilterThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment").filter("amount" > 10).totals("amount", metric: .sum, group: "product")
        }
    }

    @Test("A shape nothing grids says so")
    func missingShapeThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment").totals("amount", metric: .sum, group: "missing")
        }
    }
}
