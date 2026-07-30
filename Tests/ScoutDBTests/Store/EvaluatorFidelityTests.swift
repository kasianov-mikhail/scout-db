//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Evaluator fidelity")
struct EvaluatorFidelityTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(
            makeDefinition(
                entity: "pin",
                fields: [
                    FieldDefinition(name: "owner", type: .reference, storage: .slot(.reference, "r_00")),
                    FieldDefinition(name: "spot", type: .location, storage: .slot(.location, "g_00")),
                    FieldDefinition(name: "corners", type: .locationList, storage: .slot(.locationList, "lg_00")),
                    FieldDefinition(name: "blob", type: .bytes, storage: .slot(.bytes, "b_00")),
                ]))
        try await store.write(
            [
                "owner": .reference("u-1"),
                "spot": .location(latitude: 10, longitude: 20),
                "corners": .locations([GeoPoint(latitude: 1, longitude: 2)]),
                "blob": .bytes(Data([0x01])),
            ], entity: "pin", uuid: "p-1")
        try await store.write(
            [
                "owner": .reference("u-2"),
                "spot": .location(latitude: 30, longitude: 40),
                "corners": .locations([GeoPoint(latitude: 3, longitude: 4)]),
                "blob": .bytes(Data([0x02])),
            ], entity: "pin", uuid: "p-2")
    }

    private func read(_ filter: EntityStore.Filter) async throws -> [String] {
        try await store.read(entity: "pin", filters: [filter]).map(\.uuid)
    }

    @Test("A reference field answers equality, inequality and membership")
    func referenceComparisons() async throws {
        #expect(try await read(EntityStore.Filter(field: "owner", op: .equals, value: .reference("u-1"))) == ["p-1"])
        #expect(try await read(EntityStore.Filter(field: "owner", op: .notEquals, value: .reference("u-1"))) == ["p-2"])
        #expect(try await read(EntityStore.Filter(field: "owner", op: .in, value: .strings(["u-2"]))) == ["p-2"])
    }

    @Test("A location field answers equality")
    func locationEquality() async throws {
        #expect(try await read(EntityStore.Filter(field: "spot", op: .equals, value: .location(latitude: 10, longitude: 20))) == ["p-1"])
        #expect(try await read(EntityStore.Filter(field: "spot", op: .notEquals, value: .location(latitude: 10, longitude: 20))) == ["p-2"])
    }

    @Test("A location list answers membership")
    func locationMembership() async throws {
        let filter = EntityStore.Filter(field: "corners", op: .contains, value: .location(latitude: 3, longitude: 4))
        #expect(try await read(filter) == ["p-2"])
    }

    @Test("Byte ordering is a strict weak ordering")
    func byteOrdering() {
        let low = Data([0x01]) as NSData
        let high = Data([0x02]) as NSData
        #expect(PredicateEvaluator.compare(low, high) == .orderedAscending)
        #expect(PredicateEvaluator.compare(high, low) == .orderedDescending)
        #expect(PredicateEvaluator.compare(low, low) == .orderedSame)
    }

    @Test("Every server filter the store can emit is decidable locally", arguments: ServerFilter.Operator.allCases)
    func serverFiltersStayExpressible(op: ServerFilter.Operator) {
        let value: RecordValue =
            switch op {
            case .in, .notIn: .strings(["a", "b"])
            case .near: .location(latitude: 1, longitude: 2)
            default: .string("a")
            }
        let field = op == .near ? "g_00" : "s_00"
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "r"))
        record["s_00"] = "a"
        record["g_00"] = CLLocation(latitude: 1, longitude: 2)

        let filter = ServerFilter(field: field, op: op, value: value, radius: op == .near ? 10 : nil)
        #expect(PredicateEvaluator.evaluate(CKQuery(recordType: "Entity", filters: [filter]).predicate, record: record) != nil)
    }

    @Test("An inexpressible predicate is unknown, not false")
    func inexpressiblePredicate() {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "r"))
        record["s_00"] = "abc"
        #expect(PredicateEvaluator.evaluate(NSPredicate(format: "s_00 LIKE %@", "a*"), record: record) == nil)
        #expect(PredicateEvaluator.evaluate(NSPredicate(format: "s_00 == s_01"), record: record) == nil)
        #expect(PredicateEvaluator.evaluate(NSPredicate(format: "s_00 == %@", "abc"), record: record) == true)
    }
}
