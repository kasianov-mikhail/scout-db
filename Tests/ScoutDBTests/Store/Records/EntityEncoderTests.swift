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

@Suite("EntityEncoder")
struct EntityEncoderTests {
    let encoder = EntityEncoder(definition: makePurchaseDefinition())

    @Test("Encode packs the record into typed slots and the envelope")
    func encode() throws {
        let record = try encoder.encode(makePurchase())
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
