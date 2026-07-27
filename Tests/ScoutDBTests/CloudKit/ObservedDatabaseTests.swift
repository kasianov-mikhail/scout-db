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

@Suite("Observed database")
struct ObservedDatabaseTests {
    let backing = InMemoryDatabase()
    let recorder = Recorder()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        let observed = ObservedDatabase(backing: backing, observer: recorder)
        registry = SchemaRegistry(database: observed)
        store = EntityStore(database: observed, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("Store traffic reaches the observer with kinds and counts")
    func observesStoreTraffic() async throws {
        recorder.reset()
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let read = try await store.read(entity: "purchase")
        #expect(read.count == 1)

        let modify = try #require(recorder.operations.first { $0.kind == .modify })
        #expect(modify.recordCount == 1)
        #expect(modify.error == nil)
        #expect(modify.duration >= .zero)
        let query = try #require(recorder.operations.last { $0.kind == .query })
        #expect(query.recordCount == 1)
    }

    @Test("Constraint validation reads a batch, not a record at a time")
    func constraintValidationBatches() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "seat", version: 1,
                fields: [
                    FieldDefinition(name: "row", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "number", type: .int, storage: .slot(.int, "i_00")),
                    FieldDefinition(name: "badge", type: .string, storage: .slot(.string, "s_01"), references: "person", exclusive: true),
                ], uniqueKeys: [["row", "number"]]))

        func reads(writing count: Int, from start: Int) async throws -> Int {
            recorder.reset()
            try await store.write(
                (start..<(start + count)).map { index in
                    EntityWrite(values: ["row": .string("r"), "number": .int(Int64(index)), "badge": .string("b-\(index)")], uuid: "s-\(index)")
                }, entity: "seat")
            return recorder.operations.filter { $0.kind == .query || $0.kind == .continuation }.count
        }

        let one = try await reads(writing: 1, from: 0)
        let many = try await reads(writing: 20, from: 100)
        #expect(many == one)
    }

    @Test("Claiming every key of a write costs one fetch and one conditional save")
    func claimsBatchAcrossKeys() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "ticket", version: 1,
                fields: [
                    FieldDefinition(name: "row", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "number", type: .int, storage: .slot(.int, "i_00")),
                    FieldDefinition(name: "serial", type: .string, storage: .slot(.string, "s_01")),
                    FieldDefinition(name: "badge", type: .string, storage: .slot(.string, "s_02"), references: "person", exclusive: true),
                    FieldDefinition(name: "locker", type: .string, storage: .slot(.string, "s_03"), references: "locker", exclusive: true),
                ], enforcedKeys: [["row", "number"], ["serial"]]))

        func calls(_ kind: DatabaseOperation.Kind, writing count: Int, from start: Int) async throws -> Int {
            recorder.reset()
            try await store.write(
                (start..<(start + count)).map { index in
                    EntityWrite(
                        values: [
                            "row": .string("r"), "number": .int(Int64(index)), "serial": .string("s-\(index)"),
                            "badge": .string("b-\(index)"), "locker": .string("l-\(index)"),
                        ], uuid: "t-\(index)")
                }, entity: "ticket")
            return recorder.operations.filter { $0.kind == kind }.count
        }

        #expect(try await calls(.fetch, writing: 1, from: 0) == 1)
        #expect(try await calls(.conditionalSave, writing: 1, from: 0) == 0)
        #expect(try await calls(.fetch, writing: 20, from: 100) == 1)
        #expect(try await calls(.conditionalSave, writing: 20, from: 200) == 1)
    }

    @Test("A batch of orphaned claims is adopted in a fixed number of round trips")
    func orphanedClaimsAdoptTogether() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "badge", version: 1,
                fields: [FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00"))],
                enforcedKeys: [["code"]]))

        func adopting(_ count: Int, from start: Int) async throws -> Int {
            let codes = (start..<(start + count)).map { "c-\($0)" }
            try await store.write(codes.map { EntityWrite(values: ["code": .string($0)], uuid: "old-\($0)") }, entity: "badge")
            backing.records.removeAll { ($0["uuid"] as? String)?.hasPrefix("old-") == true }
            recorder.reset()
            try await store.write(codes.map { EntityWrite(values: ["code": .string($0)], uuid: "new-\($0)") }, entity: "badge")
            return recorder.operations.filter { $0.kind == .fetch || $0.kind == .conditionalSave }.count
        }

        let one = try await adopting(1, from: 0)
        #expect(try await adopting(20, from: 100) == one)
        #expect(backing.records.filter { $0.recordType == "UniqueClaim" }.allSatisfy { ($0["owner"] as? String)?.hasPrefix("new-") == true })
    }

    @Test("A write under fresh uuids skips the read that looks for their old view rows")
    func freshWritesSkipTheLiveRead() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "payment", version: 1,
                fields: [
                    FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "amount", type: .double, storage: .slot(.double, "d_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", views: [AggregateView(name: "daily", groupBy: "product", bucket: .day)]))

        func fetches(_ batch: [EntityWrite]) async throws -> Int {
            recorder.reset()
            try await store.write(batch, entity: "payment")
            return recorder.operations.filter { $0.kind == .fetch }.count
        }

        let values: [String: RecordValue] = ["product": .string("app"), "amount": .double(1), "date": .date(Date())]
        _ = try await fetches([EntityWrite(values: values)])
        let fresh = try await fetches([EntityWrite(values: values), EntityWrite(values: values)])
        let named = try await fetches([EntityWrite(values: values, uuid: "p-1"), EntityWrite(values: values, uuid: "p-2")])
        #expect(named == fresh + 1)
    }

    @Test("A failing call reports its error and still throws")
    func observesFailures() async throws {
        recorder.reset()
        backing.writeErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        }

        let failed = try #require(recorder.operations.first { $0.error != nil })
        #expect(failed.kind == .modify)
        #expect(failed.error?.contains("CKError") == true)
    }

    @Test("The decorator composes around the offline cache")
    func composesWithOfflineCache() async throws {
        let recorder = Recorder()
        let observed = ObservedDatabase(backing: OfflineCache(backing: backing), observer: recorder)
        let registry = SchemaRegistry(database: observed)
        let store = EntityStore(database: observed, registry: registry)
        try await registry.publish(makePurchaseDefinition())
        recorder.reset()

        backing.writeErrors = [CKError(.networkFailure)]
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let modify = try #require(recorder.operations.first { $0.kind == .modify })
        #expect(modify.error == nil)
    }
}

extension ObservedDatabaseTests {
    @Test("A transaction's update steps cost the round trips of a single update")
    func transactionUpdatesBatch() async throws {
        try await registry.publish(EntityStore.transactionDefinition)

        func calls(patching count: Int, from start: Int) async throws -> Int {
            for index in start..<(start + count) {
                try await store.write(makePurchase().values, entity: "purchase", uuid: "p-\(index)")
            }
            recorder.reset()
            try await store.transaction { draft in
                for index in start..<(start + count) {
                    draft.update(["quantity": .int(Int64(index))], entity: "purchase", uuid: "p-\(index)")
                }
            }
            return recorder.operations.count
        }

        _ = try await calls(patching: 1, from: 0)
        let one = try await calls(patching: 1, from: 10)
        let many = try await calls(patching: 20, from: 100)
        #expect(many == one)
        #expect(try await store.fetch(entity: "purchase", uuids: ["p-119"]).first?.values["quantity"] == .int(119))
    }

    @Test("A keyset page after a cursor costs the same requests as the first")
    func keysetPageRequestParity() async throws {
        for index in 0..<6 {
            try await store.write(
                ["product_id": .string("sku-\(index)"), "date": .date(Date(timeIntervalSince1970: TimeInterval(index * 1_000)))],
                entity: "purchase", uuid: "p-\(index)")
        }

        func requests(_ body: () async throws -> Void) async throws -> Int {
            recorder.reset()
            try await body()
            return recorder.operations.filter { $0.kind == .query || $0.kind == .continuation }.count
        }

        var first = EntityPage(records: [], cursor: nil)
        let opening = try await requests { first = try await store.read(entity: "purchase", limit: 3) }
        #expect(first.records.map(\.uuid) == ["p-0", "p-1", "p-2"])
        #expect(opening == 1)

        var second = EntityPage(records: [], cursor: nil)
        let continued = try await requests { second = try await store.read(entity: "purchase", limit: 3, after: first.cursor) }
        #expect(second.records.map(\.uuid) == ["p-3", "p-4", "p-5"])
        #expect(continued == 1)
    }

    @Test("An orphan sweep probes its parents by the page, not a hundred records at a time")
    func orphanSweepProbesByPage() async throws {
        try await registry.publish(
            EntityDefinition(
                entity: "author", version: 1,
                fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))]))
        try await registry.publish(
            EntityDefinition(
                entity: "book", version: 1,
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "author_id", type: .string, storage: .slot(.string, "s_01"), references: "author"),
                ]))
        try await store.write((0..<250).map { EntityWrite(values: ["name": .string("a-\($0)")], uuid: "a-\($0)") }, entity: "author")
        try await store.write(
            (0..<250).map { EntityWrite(values: ["title": .string("t-\($0)"), "author_id": .string("a-\($0)")], uuid: "b-\($0)") }, entity: "book")
        try await store.delete(entity: "author", uuid: "a-7")

        recorder.reset()
        let orphaned = try await store.orphans(entity: "book", field: "author_id")
        #expect(orphaned.map(\.uuid) == ["b-7"])

        #expect(recorder.operations.filter { $0.kind == .fetch }.isEmpty)
        #expect(recorder.operations.filter { $0.kind == .query || $0.kind == .continuation }.count <= 4)
    }

    @Test("A capped read escalates its page size instead of one request per scanned record")
    func boundedReadEscalatesPages() async throws {
        for index in 0..<60 {
            try await store.write(
                ["product_id": .string("sku-\(index % 3)"), "date": .date(Date(timeIntervalSince1970: TimeInterval(index)))],
                entity: "purchase", uuid: "p-\(index)")
        }

        func requests(_ body: () async throws -> Void) async throws -> Int {
            recorder.reset()
            try await body()
            return recorder.operations.filter { $0.kind == .query || $0.kind == .continuation }.count
        }

        var missing: EntityRecord?
        let exhausted = try await requests { missing = try await store.query("purchase").exclude("product_id", .beginsWith, "sku").first() }
        #expect(missing?.uuid == nil)
        #expect(exhausted <= 8)

        var scanned: [EntityRecord] = []
        let partial = try await requests { scanned = try await store.query("purchase").exclude("product_id", .equals, "sku-0").limit(5).all() }
        #expect(scanned.count == 5)
        #expect(scanned.allSatisfy { $0.values["product_id"] != .string("sku-0") })
        #expect(partial <= 3)

        var served: [EntityRecord] = []
        let capped = try await requests { served = try await store.query("purchase").filter("product_id", .equals, "sku-1").limit(5).all() }
        #expect(served.count == 5)
        #expect(capped == 1)
    }

    @Test("A sorted OR read bounds every branch instead of draining it")
    func sortedBranchesAreBounded() async throws {
        for index in 0..<40 {
            try await store.write(
                [
                    "product_id": .string(index.isMultiple(of: 2) ? "sku-a" : "sku-b"), "quantity": .int(Int64(index)),
                    "date": .date(Date(timeIntervalSince1970: TimeInterval(index))),
                ], entity: "purchase", uuid: "p-\(index)")
        }

        recorder.reset()
        let top = try await store.query("purchase")
            .group {
                $0.filter("product_id", .equals, "sku-a")
                $0.filter("quantity", .greaterThanOrEquals, .int(30))
            }
            .sort("quantity", .descending)
            .limit(5)
            .all()

        #expect(top.map { $0.values["quantity"] } == [39, 38, 37, 36, 35].map { RecordValue.int(Int64($0)) })
        let pages = recorder.operations.filter { $0.kind == .query || $0.kind == .continuation }
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0.recordCount <= 6 })
    }

    @Test("A capped read asks its first page for the rows it needs plus the boundary row, not for every match")
    func boundedReadSizesItsFirstPage() async throws {
        for index in 0..<60 {
            try await store.write(
                ["product_id": .string("sku-1"), "date": .date(Date(timeIntervalSince1970: TimeInterval(index)))],
                entity: "purchase", uuid: "p-\(index)")
        }

        recorder.reset()
        let served = try await store.query("purchase").filter("product_id", .equals, "sku-1").limit(5).all()
        #expect(served.count == 5)

        let first = try #require(recorder.operations.first { $0.kind == .query })
        #expect(first.recordCount == 6)
    }
}

final class Recorder: DatabaseObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [DatabaseOperation] = []

    var operations: [DatabaseOperation] {
        lock.withLock { collected }
    }

    func record(_ operation: DatabaseOperation) {
        lock.withLock { collected.append(operation) }
    }

    func reset() {
        lock.withLock { collected = [] }
    }
}
