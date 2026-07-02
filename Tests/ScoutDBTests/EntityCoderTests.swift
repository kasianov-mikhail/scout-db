//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("EntityCoder")
struct EntityCoderTests {
    let coder = EntityCoder()
    let definition = makePurchaseDefinition()

    @Test("Encode packs the record into typed slots and the envelope")
    func encode() throws {
        let record = try coder.encode(makePurchase(), using: definition)
        #expect(record.recordType == "Item")
        #expect(record.recordID == "p-1")
        #expect(record["entity"] == "purchase")
        #expect(record["schema_version"] == Int64(2))
        #expect(record["uuid"] == "p-1")
        #expect(record["s_00"] == "sku-42")
        #expect(record["i_01"] == Int64(3))
        #expect(record["d_00"] == 29.97)
        #expect(record["t_00"] == Date(timeIntervalSince1970: 1_000_000))
        #expect(record.fields["payload"] != nil)
    }

    @Test("Decode restores the encoded record")
    func roundTrip() throws {
        let purchase = makePurchase()
        let record = try coder.encode(purchase, using: definition)
        let decoded = try coder.decode(record, using: definition)
        #expect(decoded == purchase)
    }

    @Test("Old records decode through their own version")
    func versionedDecode() throws {
        let old = EntityRecord(
            entity: "purchase", uuid: "p-2", schemaVersion: 1,
            values: [
                "product_id": .string("sku-1"),
                "amount": .int(500),
            ])
        let record = try coder.encode(old, using: definition)
        let decoded = try coder.decode(record, using: definition)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.values["amount"] == .int(500))
        #expect(decoded.values["quantity"] == nil)
    }

    @Test("Encode rejects a value of the wrong type")
    func typeMismatch() {
        var purchase = makePurchase()
        purchase.values["quantity"] = .string("three")
        #expect(throws: SchemaError.typeMismatch("quantity")) {
            try coder.encode(purchase, using: definition)
        }
    }

    @Test("Encode rejects a field missing from the definition")
    func unknownField() {
        var purchase = makePurchase()
        purchase.values["color"] = .string("red")
        #expect(throws: SchemaError.unknownField("color")) {
            try coder.encode(purchase, using: definition)
        }
    }

    @Test("Decode refuses records newer than the definition")
    func staleSchema() throws {
        var record = Record(recordType: "Item", recordID: "p-3")
        record["entity"] = "purchase"
        record["schema_version"] = Int64(3)
        record["uuid"] = "p-3"
        #expect(throws: SchemaError.staleSchema(entity: "purchase", version: 3)) {
            try coder.decode(record, using: definition)
        }
    }

    @Test("Defaults fill missing values")
    func defaults() throws {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "level", type: .string, storage: .slot(.string, "s_00"), defaultValue: .string("info"))
            ])
        let resolved = try coder.resolve([:], at: 2, using: definition)
        #expect(resolved["level"] == .string("info"))
    }

    @Test("Missing required field throws")
    func requiredField() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"), required: true)
            ])
        #expect(throws: SchemaError.missingField("name")) {
            try coder.resolve([:], at: 2, using: definition)
        }
    }

    @Test("Value outside the enum domain throws")
    func allowedDomain() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "level", type: .string, storage: .slot(.string, "s_00"), allowed: ["info", "error"])
            ])
        #expect(throws: SchemaError.invalidValue("level")) {
            try coder.resolve(["level": .string("debug")], at: 2, using: definition)
        }
    }

    @Test("Value below the minimum throws")
    func range() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_00"), minimum: 0)
            ])
        #expect(throws: SchemaError.invalidValue("count")) {
            try coder.resolve(["count": .int(-1)], at: 2, using: definition)
        }
    }

    @Test("Derived fields are materialized by the coder")
    func derived() throws {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "name_lower", type: .string, storage: .slot(.string, "s_01"), derived: Derivation(source: "name", transform: .lowercase)),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                FieldDefinition(name: "day", type: .timestamp, storage: .slot(.timestamp, "t_01"), derived: Derivation(source: "date", transform: .day)),
            ])
        let resolved = try coder.resolve(
            [
                "name": .string("Sign Up"),
                "date": .date(Date(timeIntervalSince1970: 108_123)),
            ], at: 2, using: definition)
        #expect(resolved["name_lower"] == .string("sign up"))
        #expect(resolved["day"] == .date(Date(timeIntervalSince1970: 86_400)))
    }

    @Test("Natural key produces a deterministic uuid")
    func naturalKey() throws {
        let definition = makeDefinition(
            entity: "profile",
            fields: [
                FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00"))
            ], unique: ["user_id"])
        let first = try coder.naturalUUID(for: ["user_id": .string("alice")], using: definition)
        let second = try coder.naturalUUID(for: ["user_id": .string("alice")], using: definition)
        let other = try coder.naturalUUID(for: ["user_id": .string("bob")], using: definition)
        #expect(first != nil)
        #expect(first == second)
        #expect(first != other)
    }

    @Test("TTL stamps an expires envelope field")
    func expires() throws {
        let definition = makeDefinition(
            entity: "ping",
            fields: [
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"))
            ], envelopeDate: "date", ttl: 3_600)
        let ping = EntityRecord(entity: "ping", uuid: "g-1", schemaVersion: 2, values: ["date": .date(Date(timeIntervalSince1970: 1_000))])
        let record = try coder.encode(ping, using: definition)
        #expect(record["expires"] == Date(timeIntervalSince1970: 4_600))
    }
}

func makePurchase(uuid: String = "p-1") -> EntityRecord {
    EntityRecord(
        entity: "purchase", uuid: uuid, schemaVersion: 2,
        values: [
            "product_id": .string("sku-42"),
            "date": .date(Date(timeIntervalSince1970: 1_000_000)),
            "quantity": .int(3),
            "total": .double(29.97),
            "comment": .string("gift"),
        ])
}
