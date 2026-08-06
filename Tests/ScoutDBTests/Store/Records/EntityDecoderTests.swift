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

@Suite("EntityDecoder")
struct EntityDecoderTests {
    let encoder = EntityEncoder(definition: makePurchaseDefinition())
    let decoder = EntityDecoder(definition: makePurchaseDefinition())

    @Test("Decode restores the encoded record")
    func roundTrip() throws {
        let purchase = makePurchase()
        let record = try encoder.encode(purchase)
        let decoded = try decoder.decode(record)
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
        let record = try encoder.encode(old)
        let decoded = try decoder.decode(record)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.values["amount"] == .int(500))
        #expect(decoded.values["quantity"] == nil)
    }

    @Test("Decode refuses records newer than the definition")
    func staleSchema() throws {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "p-3"))
        record[Envelope.entity] = "purchase"
        record[Envelope.version] = Int64(3)
        record[Envelope.uuid] = "p-3"
        #expect(throws: SchemaError.staleSchema(entity: "purchase", version: 3)) {
            try decoder.decode(record)
        }
    }

    @Test("Empty typed lists in slots keep their declared kind through a round-trip")
    func emptyTypedLists() throws {
        let definition = makeDefinition(
            entity: "lists",
            fields: [
                FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                FieldDefinition(name: "counts", type: .intList, storage: .slot(.intList, "li_00")),
                FieldDefinition(name: "ratios", type: .doubleList, storage: .slot(.doubleList, "ld_00")),
                FieldDefinition(name: "times", type: .timestampList, storage: .slot(.timestampList, "lt_00")),
            ]
        )
        let record = EntityRecord(
            entity: "lists",
            uuid: "l-1",
            schemaVersion: 2,
            values: ["tags": .strings([]), "counts": .ints([]), "ratios": .doubles([]), "times": .dates([])]
        )
        let encoded = try EntityEncoder(definition: definition).encode(record)
        let decoded = try EntityDecoder(definition: definition).decode(encoded)
        #expect(decoded.values["tags"] == .strings([]))
        #expect(decoded.values["counts"] == .ints([]))
        #expect(decoded.values["ratios"] == .doubles([]))
        #expect(decoded.values["times"] == .dates([]))
    }
}
