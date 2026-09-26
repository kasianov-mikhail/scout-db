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

@Suite("InMemory record names")
struct InMemoryNameTests {
    let database = InMemoryDatabase()

    private func makeRecord(named name: String) -> CKRecord {
        CKRecord(recordType: "Thing", recordID: CKRecord.ID(recordName: name))
    }

    @Test(
        "A name CloudKit refuses is refused here too",
        arguments: ["_leading", "__schema@purchase", "with space", "at@sign", "sla/sh"]
    )
    func illegalNamesAreRefused(name: String) async throws {
        await #expect(throws: CKError.self) {
            try await database.modifyRecords(saving: [makeRecord(named: name)], deleting: [])
        }
        #expect(database.records.count == 0)
    }

    @Test("A conditional save reports the refusal per record")
    func illegalNameFailsConditionalSave() async throws {
        let results = try await database.saveIfUnchanged([makeRecord(named: "_leading")])
        let result = try #require(results.first?.1)

        guard case .failure(let error) = result else {
            Issue.record("Expected the illegal name to be refused")
            return
        }
        #expect((error as? CKError)?.code == .invalidArguments)
    }

    @Test("The names the library writes are ones CloudKit takes", arguments: ["purchase", "order line", "Ünïcøde"])
    func libraryNamesAreLegal(entity: String) {
        let slot = VectorSlot(entity: entity, aggregate: "by_product_id", group: "sku-1", shard: nil, week: .now)
        let index = VectorIndex(entity: entity, aggregate: "by_product_id", week: nil)

        #expect(SchemaDescriptorEntry.recordID(for: entity).isLegalRecordName)
        #expect(slot.recordID.isLegalRecordName)
        #expect(index.recordID.isLegalRecordName)
    }
}
