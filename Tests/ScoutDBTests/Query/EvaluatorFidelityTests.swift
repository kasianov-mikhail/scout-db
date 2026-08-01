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
                    FieldDefinition(name: "blob", type: .bytes, storage: .slot(.bytes, "b_00")),
                ]
            )
        )
        try await store.write(
            [EntityWrite(values: ["owner": .reference("u-1"), "blob": .bytes(Data([0x01]))], uuid: "p-1")],
            entity: "pin")
        try await store.write(
            [EntityWrite(values: ["owner": .reference("u-2"), "blob": .bytes(Data([0x02]))], uuid: "p-2")],
            entity: "pin")
    }

    private func read(_ filter: Filter) async throws -> [String] {
        try await EntityReader(store: store, entity: "pin").read(any: [[filter]]).map(\.uuid)
    }

    @Test("A reference field answers equality, inequality and membership")
    func referenceComparisons() async throws {
        #expect(try await read(Filter(field: "owner", op: .equals, value: .reference("u-1"))) == ["p-1"])
        #expect(try await read(Filter(field: "owner", op: .notEquals, value: .reference("u-1"))) == ["p-2"])
        #expect(try await read(Filter(field: "owner", op: .in, value: .strings(["u-2"]))) == ["p-2"])
    }

    @Test("Byte ordering is a strict weak ordering")
    func byteOrdering() {
        let low = Data([0x01]) as NSData
        let high = Data([0x02]) as NSData
        #expect(PredicateEvaluator.compare(low, high) == .orderedAscending)
        #expect(PredicateEvaluator.compare(high, low) == .orderedDescending)
        #expect(PredicateEvaluator.compare(low, low) == .orderedSame)
    }

    @Test("Every server filter the store can emit is decidable locally", arguments: Operator.allCases)
    func serverFiltersStayExpressible(op: Operator) {
        let value: RecordValue =
            switch op {
            case .in, .notIn: .strings(["a", "b"])
            default: .string("a")
            }
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "r"))
        record["s_00"] = "a"

        let filter = ServerFilter(field: "s_00", op: op, value: value)
        #expect(
            PredicateEvaluator.evaluate(CKQuery(recordType: "Entity", filters: [filter]).predicate, record: record)
                != nil
        )
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
