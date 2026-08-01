//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import Testing

@testable import ScoutDB

@Suite("Contract: store")
struct StoreContractTests {
    @Test("A write round-trips every field type through a read")
    func roundTrip() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            let date = Date(timeIntervalSince1970: 1_000_000)
            try await f.store.write(orderValues(product: "sku-9", quantity: 4, total: 19.5, date: date, note: "gift"), entity: entity, uuid: "r-1")

            try await eventually { try await f.store.read(entity: entity).count == 1 }
            let record = try #require(try await f.store.read(entity: entity).first)
            #expect(record.uuid == "r-1")
            #expect(record.values["product"] == .string("sku-9"))
            #expect(record.values["quantity"] == .int(4))
            #expect(record.values["total"] == .double(19.5))
            #expect(record.values["date"] == .date(date))
            #expect(record.values["note"] == .string("gift"))
        }
    }

    @Test("A repeated uuid upserts instead of duplicating")
    func upsertSameUUID() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(quantity: 1), entity: entity, uuid: "u-1")
            try await f.store.write(orderValues(quantity: 7), entity: entity, uuid: "u-1")

            try await eventually {
                let records = try await f.store.read(entity: entity)
                return records.count == 1 && records.first?.values["quantity"] == .int(7)
            }
        }
    }

    @Test("A unique key derives the same uuid for the same values")
    func uniqueKeyNaturalUUID() async throws {
        try await withContract { f in
            let entity = try await f.publish(
                "visit",
                fields: [
                    FieldDefinition(name: "user", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], unique: ["user"])
            try await f.store.write(["user": .string("u1"), "date": .date(Date())], entity: entity)
            try await f.store.write(["user": .string("u1"), "date": .date(Date())], entity: entity)

            try await eventually { try await f.store.read(entity: entity).count == 1 }
        }
    }

    @Test("A delete hides the record, and a rewrite of its uuid brings it back")
    func deleteAndRewrite() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(product: "keep-me"), entity: entity, uuid: "d-1")
            try await eventually { try await f.store.read(entity: entity).count == 1 }

            try await f.store.delete(entity: entity, uuid: "d-1")
            try await eventually { try await f.store.read(entity: entity).isEmpty }

            try await f.store.write(orderValues(product: "keep-me"), entity: entity, uuid: "d-1")
            try await eventually { try await f.store.read(entity: entity).count == 1 }
            #expect(try await f.store.fetch(entity: entity, uuids: ["d-1"]).first?.values["product"] == .string("keep-me"))
        }
    }

    @Test("Equality and range filters narrow server-side")
    func equalityAndRangeFilters() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [1, 5, 9].enumerated() {
                try await f.store.write(orderValues(product: "sku-\(quantity)", quantity: quantity), entity: entity, uuid: "q-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            let exact = try await f.store.read(entity: entity, filters: [.init(field: "product", op: .equals, value: .string("sku-5"))])
            #expect(exact.map(\.uuid) == ["q-1"])

            let above = try await f.store.read(entity: entity, filters: [.init(field: "quantity", op: .greaterThan, value: .int(4))])
            #expect(Set(above.map(\.uuid)) == ["q-1", "q-2"])

            let middle = try await f.store.query(entity).filter("quantity" >= 2 && "quantity" < 9).take(100)
            #expect(middle.map(\.uuid) == ["q-1"])
        }
    }

    @Test("IN filters match any of the listed values")
    func inFilter() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for product in ["a", "b", "c"] {
                try await f.store.write(orderValues(product: product), entity: entity, uuid: "in-\(product)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            let picked = try await f.store.read(entity: entity, filters: [.init(field: "product", op: .in, value: .strings(["a", "c"]))])
            #expect(Set(picked.map(\.uuid)) == ["in-a", "in-c"])
        }
    }

    @Test("Substring CONTAINS falls back to a client-side matcher")
    func containsSubstring() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(product: "deluxe-bundle"), entity: entity, uuid: "s-1")
            try await f.store.write(orderValues(product: "basic"), entity: entity, uuid: "s-2")
            try await eventually { try await f.store.read(entity: entity).count == 2 }

            let matched = try await f.store.read(entity: entity, filters: [.init(field: "product", op: .contains, value: .string("uxe-bun"))])
            #expect(matched.map(\.uuid) == ["s-1"])
        }
    }

    @Test("A slot-backed sort orders server-side in both directions")
    func serverSortOrders() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [5, 1, 9].enumerated() {
                try await f.store.write(orderValues(quantity: quantity), entity: entity, uuid: "o-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            let ascending = try await f.store.read(entity: entity, sort: [.init(field: "quantity")])
            #expect(ascending.map(\.uuid) == ["o-1", "o-0", "o-2"])
            let descending = try await f.store.read(entity: entity, sort: [.init(field: "quantity", ascending: false)])
            #expect(descending.map(\.uuid) == ["o-2", "o-0", "o-1"])
        }
    }

    @Test("Keyset pages are disjoint, ordered, and exhaustive")
    func keysetPagination() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            let base = Date(timeIntervalSince1970: 1_000_000)
            for index in 0..<5 {
                try await f.store.write(orderValues(date: base.addingTimeInterval(Double(index) * 60)), entity: entity, uuid: "p-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 5 }

            let first = try await f.store.read(entity: entity, orderedBy: "date", limit: 2)
            #expect(first.records.map(\.uuid) == ["p-0", "p-1"])
            let second = try await f.store.read(entity: entity, orderedBy: "date", limit: 2, after: first.cursor)
            #expect(second.records.map(\.uuid) == ["p-2", "p-3"])
            let last = try await f.store.read(entity: entity, orderedBy: "date", limit: 2, after: second.cursor)
            #expect(last.records.map(\.uuid) == ["p-4"])
            #expect(last.cursor == nil)
        }
    }

    @Test("A projected read serves the requested fields")
    func projectionFields() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(orderValues(product: "sku-2", quantity: 3), entity: entity, uuid: "f-1")
            try await eventually { try await f.store.read(entity: entity).count == 1 }

            let projected = try #require(try await f.store.read(entity: entity, fields: ["product"]).first)
            #expect(projected.values["product"] == .string("sku-2"))
        }
    }

    @Test("Folds aggregate matching records")
    func foldSum() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, total) in [2.5, 7.5, 10.0].enumerated() {
                try await f.store.write(orderValues(total: total), entity: entity, uuid: "fs-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            #expect(try await f.store.query(entity).sum("total") == 20)
            #expect(try await f.store.query(entity).max("total") == 10)
        }
    }

    @Test("Counts group records by a field's values")
    func countsByGroup() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, product) in ["a", "a", "b"].enumerated() {
                try await f.store.write(orderValues(product: product), entity: entity, uuid: "cg-\(index)")
            }
            try await eventually { try await f.store.read(entity: entity).count == 3 }

            #expect(try await f.store.query(entity).count(by: "product") == ["a": 2, "b": 1])
        }
    }

    @Test("Aggregate views fold writes into totals")
    func aggregateViewTotals() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder(views: [AggregateView(name: "revenue", sum: "total")])
            try await f.store.write(orderValues(total: 2), entity: entity, uuid: "v-1")
            try await f.store.write(orderValues(total: 3), entity: entity, uuid: "v-2")

            try await eventually {
                let totals = try await GridQuery(f.store, entity: entity, view: "revenue").totals()
                return totals.first?.count == 2 && totals.first?.value == 5
            }
        }
    }
}
