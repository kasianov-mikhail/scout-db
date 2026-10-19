//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation
import Testing

@testable import ScoutDB

@Suite("Asset")
struct AssetTests {
    @Test("An asset converts to and from its record value")
    func conversion() {
        let asset = Asset(data: Data([1, 2, 3]))

        #expect(asset.recordValue == .asset(Data([1, 2, 3])))
        #expect(Asset(recordValue: .asset(Data([1, 2, 3]))) == asset)
        #expect(Asset(recordValue: .bytes(Data([1, 2, 3]))) == nil)
    }

    @Test("An asset value survives the payload's JSON coding")
    func payloadCoding() throws {
        let value = RecordValue.asset(Data([4, 5]))

        #expect(try JSONDecoder().decode(RecordValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test("An asset field takes an asset value and nothing else")
    func fieldTypeMatching() {
        #expect(FieldType.asset.matches(value: .asset(Data())))
        #expect(!FieldType.asset.matches(value: .bytes(Data())))
        #expect(!FieldType.bytes.matches(value: .asset(Data())))
    }

    @Test("No filter can reach an asset field")
    func filters() {
        let definition = makeDefinition(
            entity: "files",
            fields: [FieldDefinition(name: "table", type: .asset, storage: .slot(.asset, "a_00"))]
        )
        let filter = ClientFilter(field: "table", op: .equals, value: .asset(Data()))

        #expect(throws: SchemaError.unsupportedQuery(.unfilterableField("table"))) {
            try definition.serverFilters(filters: [filter])
        }
        #expect(throws: SchemaError.unsupportedQuery(.unfilterableField("table"))) {
            try definition.clientFilters(filters: [filter])
        }
    }
}
