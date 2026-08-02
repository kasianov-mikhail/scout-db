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
            try await f.store.write(
                [
                    EntityWrite(
                        values: orderValues(product: "sku-9", quantity: 4, total: 19.5, date: date, note: "gift"),
                        uuid: "r-1")
                ], entity: entity)

            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 1 }
            let record = try #require(try await ReadOperation(store: f.store, entity: entity).read().first)
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
            try await f.store.write([EntityWrite(values: orderValues(quantity: 1), uuid: "u-1")], entity: entity)
            try await f.store.write([EntityWrite(values: orderValues(quantity: 7), uuid: "u-1")], entity: entity)

            try await eventually {
                let records = try await ReadOperation(store: f.store, entity: entity).read()
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
                ],
                unique: ["user"]
            )
            try await f.store.write(
                [EntityWrite(values: ["user": .string("u1"), "date": .date(Date())], uuid: nil)], entity: entity)
            try await f.store.write(
                [EntityWrite(values: ["user": .string("u1"), "date": .date(Date())], uuid: nil)], entity: entity)

            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 1 }
        }
    }

    @Test("Equality and range filters narrow server-side")
    func equalityAndRangeFilters() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [1, 5, 9].enumerated() {
                try await f.store.write(
                    [
                        EntityWrite(
                            values: orderValues(product: "sku-\(quantity)", quantity: quantity), uuid: "q-\(index)")
                    ], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 3 }

            let exact = try await ReadOperation(store: f.store, entity: entity)
                .read(branches: [[.init(field: "product", op: .equals, value: .string("sku-5"))]])
            #expect(exact.map(\.uuid) == ["q-1"])

            let above = try await ReadOperation(store: f.store, entity: entity)
                .read(branches: [[.init(field: "quantity", op: .greaterThan, value: .int(4))]])
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
                try await f.store.write(
                    [EntityWrite(values: orderValues(product: product), uuid: "in-\(product)")], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 3 }

            let picked = try await ReadOperation(store: f.store, entity: entity)
                .read(branches: [[.init(field: "product", op: .in, value: .strings(["a", "c"]))]])
            #expect(Set(picked.map(\.uuid)) == ["in-a", "in-c"])
        }
    }

    @Test("Substring CONTAINS falls back to a client-side matcher")
    func containsSubstring() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write(
                [EntityWrite(values: orderValues(product: "deluxe-bundle"), uuid: "s-1")], entity: entity)
            try await f.store.write([EntityWrite(values: orderValues(product: "basic"), uuid: "s-2")], entity: entity)
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 2 }

            let matched = try await ReadOperation(store: f.store, entity: entity)
                .read(branches: [[.init(field: "product", op: .contains, value: .string("uxe-bun"))]])
            #expect(matched.map(\.uuid) == ["s-1"])
        }
    }

    @Test("A slot-backed sort orders server-side in both directions")
    func serverSortOrders() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, quantity) in [5, 1, 9].enumerated() {
                try await f.store.write(
                    [EntityWrite(values: orderValues(quantity: quantity), uuid: "o-\(index)")], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 3 }

            let ascending = try await ReadOperation(
                store: f.store, entity: entity, sort: [.init(field: "quantity")]
            ).read()
            #expect(ascending.map(\.uuid) == ["o-1", "o-0", "o-2"])
            let descending = try await ReadOperation(
                store: f.store, entity: entity, sort: [.init(field: "quantity", ascending: false)]
            ).read()
            #expect(descending.map(\.uuid) == ["o-2", "o-0", "o-1"])
        }
    }

    @Test("Keyset pages are disjoint, ordered, and exhaustive")
    func keysetPagination() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            let base = Date(timeIntervalSince1970: 1_000_000)
            for index in 0..<5 {
                try await f.store.write(
                    [
                        EntityWrite(
                            values: orderValues(date: base.addingTimeInterval(Double(index) * 60)), uuid: "p-\(index)")
                    ], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 5 }

            let first = try await f.store.query(entity).sort("date").page(size: 2)
            #expect(first.records.map(\.uuid) == ["p-0", "p-1"])
            let second = try await f.store.query(entity).sort("date").page(size: 2, after: first.cursor)
            #expect(second.records.map(\.uuid) == ["p-2", "p-3"])
            let last = try await f.store.query(entity).sort("date").page(size: 2, after: second.cursor)
            #expect(last.records.map(\.uuid) == ["p-4"])
            #expect(last.cursor == nil)
        }
    }

    @Test("Folds aggregate matching records")
    func foldSum() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            for (index, total) in [2.5, 7.5, 10.0].enumerated() {
                try await f.store.write(
                    [EntityWrite(values: orderValues(total: total), uuid: "fs-\(index)")], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 3 }

            #expect(try await f.store.query(entity).sum("total") == 20)
            #expect(try await f.store.query(entity).max("total") == 10)
        }
    }

    @Test("Counts group records by a field's values")
    func countsByGroup() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder(
                aggregates: [AggregateDefinition(name: "by_product", groupBy: "product")]
            )
            for (index, product) in ["a", "a", "b"].enumerated() {
                try await f.store.write(
                    [EntityWrite(values: orderValues(product: product), uuid: "cg-\(index)")], entity: entity)
            }
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 3 }

            let totals = try await f.store.query(entity).totals(by: "product")
            #expect(totals.map(\.group) == ["a", "b"])
            #expect(totals.map(\.count) == [2, 1])
        }
    }

    @Test("Aggregate aggregates fold writes into totals")
    func aggregateViewTotals() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder(aggregates: [AggregateDefinition(name: "revenue", sum: "total")])
            try await f.store.write([EntityWrite(values: orderValues(total: 2), uuid: "v-1")], entity: entity)
            try await f.store.write([EntityWrite(values: orderValues(total: 3), uuid: "v-2")], entity: entity)

            try await eventually {
                let totals = try await TotalOperation(store: f.store, entity: entity, aggregate: "revenue").totals()
                return totals.first?.count == 2 && totals.first?.value == 5
            }
        }
    }
}
