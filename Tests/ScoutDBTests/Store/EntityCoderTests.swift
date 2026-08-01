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

@Suite("EntityCoder")
struct EntityCoderTests {
    let coder = EntityCoder(definition: makePurchaseDefinition())

    @Test("Encode packs the record into typed slots and the envelope")
    func encode() throws {
        let record = try coder.encode(makePurchase())
        #expect(record.recordType == "Entity")
        #expect(record.recordID.recordName == "p-1")
        #expect(record["entity"] == "purchase")
        #expect(record["schema_version"] == Int64(2))
        #expect(record["uuid"] == "p-1")
        #expect(record["s_00"] == "sku-42")
        #expect(record["i_01"] == Int64(3))
        #expect(record["d_00"] == 29.97)
        #expect(record["t_00"] == Date(timeIntervalSince1970: 1_000_000))
        #expect(record["payload"] != nil)
    }

    @Test("Decode restores the encoded record")
    func roundTrip() throws {
        let purchase = makePurchase()
        let record = try coder.encode(purchase)
        let decoded = try coder.decode(record)
        #expect(decoded == purchase)
    }

    @Test("Old records decode through their own version")
    func versionedDecode() throws {
        let old = EntityRecord(
            entity: "purchase",
            uuid: "p-2",
            schemaVersion: 1,
            values: [
                "product_id": .string("sku-1"),
                "amount": .int(500),
            ]
        )
        let record = try coder.encode(old)
        let decoded = try coder.decode(record)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.values["amount"] == .int(500))
        #expect(decoded.values["quantity"] == nil)
    }

    @Test("Resolve rejects a value of the wrong type")
    func typeMismatch() {
        var purchase = makePurchase()
        purchase.values["quantity"] = .string("three")
        #expect(throws: SchemaError.typeMismatch("quantity")) {
            try coder.resolve(purchase.values, at: purchase.schemaVersion)
        }
    }

    @Test("Resolve rejects a field missing from the definition")
    func unknownField() {
        var purchase = makePurchase()
        purchase.values["color"] = .string("red")
        #expect(throws: SchemaError.unknownField("color")) {
            try coder.resolve(purchase.values, at: purchase.schemaVersion)
        }
    }

    @Test("Decode refuses records newer than the definition")
    func staleSchema() throws {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "p-3"))
        record["entity"] = "purchase"
        record["schema_version"] = Int64(3)
        record["uuid"] = "p-3"
        #expect(throws: SchemaError.staleSchema(entity: "purchase", version: 3)) {
            try coder.decode(record)
        }
    }

    @Test("Defaults fill missing values")
    func defaults() throws {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "log",
                fields: [
                    FieldDefinition(
                        name: "level",
                        type: .string,
                        storage: .slot(.string, "s_00"),
                        defaultValue: .string("info")
                    )
                ]
            ))
        let resolved = try coder.resolve([:], at: 2)
        #expect(resolved["level"] == .string("info"))
    }

    @Test("Missing required field throws")
    func requiredField() {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "log",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"), required: true)
                ]
            ))
        #expect(throws: SchemaError.missingField("name")) {
            try coder.resolve([:], at: 2)
        }
    }

    @Test("Value outside the enum domain throws")
    func allowedDomain() {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "log",
                fields: [
                    FieldDefinition(
                        name: "level",
                        type: .string,
                        storage: .slot(.string, "s_00"),
                        allowed: ["info", "error"]
                    )
                ]
            ))
        #expect(throws: SchemaError.invalidValue("level")) {
            try coder.resolve(["level": .string("debug")], at: 2)
        }
    }

    @Test("Value below the minimum throws")
    func range() {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "log",
                fields: [
                    FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), min: 0)
                ]
            ))
        #expect(throws: SchemaError.invalidValue("count")) {
            try coder.resolve(["count": .int(-1)], at: 2)
        }
    }

    @Test("Empty typed lists in slots keep their declared kind through a round-trip")
    func emptyTypedLists() throws {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "lists",
                fields: [
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                    FieldDefinition(name: "counts", type: .intList, storage: .slot(.intList, "li_00")),
                    FieldDefinition(name: "ratios", type: .doubleList, storage: .slot(.doubleList, "ld_00")),
                    FieldDefinition(name: "times", type: .timestampList, storage: .slot(.timestampList, "lt_00")),
                ]
            ))
        let record = EntityRecord(
            entity: "lists",
            uuid: "l-1",
            schemaVersion: 2,
            values: ["tags": .strings([]), "counts": .ints([]), "ratios": .doubles([]), "times": .dates([])]
        )
        let decoded = try coder.decode(try coder.encode(record))
        #expect(decoded.values["tags"] == .strings([]))
        #expect(decoded.values["counts"] == .ints([]))
        #expect(decoded.values["ratios"] == .doubles([]))
        #expect(decoded.values["times"] == .dates([]))
    }

    @Test("allowed constrains every element of a string list")
    func allowedList() throws {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "post",
                fields: [
                    FieldDefinition(
                        name: "tags",
                        type: .stringList,
                        storage: .slot(.stringList, "ls_00"),
                        allowed: ["red", "green"]
                    )
                ]
            ))
        #expect(throws: SchemaError.invalidValue("tags")) {
            try coder.resolve(["tags": .strings(["red", "blue"])], at: 2)
        }
        let ok = try coder.resolve(["tags": .strings(["red", "green"])], at: 2)
        #expect(ok["tags"] == .strings(["red", "green"]))
    }

    @Test("Numeric bounds constrain every element of a number list")
    func boundedList() {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "sample",
                fields: [
                    FieldDefinition(name: "counts", type: .intList, storage: .slot(.intList, "li_00"), min: 0)
                ]
            ))
        #expect(throws: SchemaError.invalidValue("counts")) {
            try coder.resolve(["counts": .ints([1, -1, 2])], at: 2)
        }
    }

    @Test("Natural key produces a deterministic uuid")
    func naturalKey() throws {
        let coder = EntityCoder(
            definition: makeDefinition(
                entity: "profile",
                fields: [
                    FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00"))
                ],
                unique: ["user_id"]
            ))
        let first = try coder.naturalUUID(for: ["user_id": .string("alice")])
        let second = try coder.naturalUUID(for: ["user_id": .string("alice")])
        let other = try coder.naturalUUID(for: ["user_id": .string("bob")])
        #expect(first != nil)
        #expect(first == second)
        #expect(first != other)
    }
}

func makePurchase(uuid: String = "p-1") -> EntityRecord {
    EntityRecord(
        entity: "purchase",
        uuid: uuid,
        schemaVersion: 2,
        values: [
            "product_id": .string("sku-42"),
            "date": .date(Date(timeIntervalSince1970: 1_000_000)),
            "quantity": .int(3),
            "total": .double(29.97),
            "comment": .string("gift"),
        ]
    )
}
