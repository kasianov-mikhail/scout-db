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

@Suite("InMemory CAS")
struct InMemoryCASTests {
    let database = InMemoryDatabase()
    let id = CKRecord.ID(recordName: "t-1")

    private func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: "Thing", recordID: id)
        record["s_01"] = "base"
        return record
    }

    private func save(_ record: CKRecord) async throws -> Result<CKRecord, any Error> {
        let results = try await database.saveIfUnchanged([record])
        guard let result = results.first?.1 else {
            return .failure(CKError(.internalError))
        }
        return result
    }

    @Test("A stale conditional save conflicts with the server copy")
    func staleSaveConflicts() async throws {
        _ = try await save(makeRecord()).get()
        let fresh = try #require(try await database.fetchRecord(id: id))
        let stale = try #require(try await database.fetchRecord(id: id))

        fresh["s_01"] = "winner"
        _ = try await save(fresh).get()

        stale["s_01"] = "loser"
        guard case .failure(let error) = try await save(stale) else {
            Issue.record("Expected the stale record to conflict")
            return
        }
        #expect((error as? RecordConflictError)?.serverRecord["s_01"] == "winner")
        #expect(database.records.first?["s_01"] == "winner")
    }

    @Test("A batch conditional save fails only its stale records")
    func batchFailsOnlyStale() async throws {
        _ = try await save(makeRecord()).get()
        let stale = try #require(try await database.fetchRecord(id: id))
        let fresh = try #require(try await database.fetchRecord(id: id))
        fresh["s_01"] = "winner"
        _ = try await save(fresh).get()

        stale["s_01"] = "loser"
        let newcomer = CKRecord(recordType: "Thing", recordID: CKRecord.ID(recordName: "t-2"))
        let results = try await database.saveIfUnchanged([stale, newcomer])

        #expect(results.count == 2)
        guard case .failure(let error) = results[0].1 else {
            Issue.record("Expected the stale record to conflict")
            return
        }
        #expect(error is RecordConflictError)
        guard case .success = results[1].1 else {
            Issue.record("Expected the new record to land")
            return
        }
        #expect(database.records.count == 2)
    }

    @Test("A tag-less save over an existing record conflicts, the blind batch path overwrites")
    func freshRecordPolicies() async throws {
        _ = try await save(makeRecord()).get()

        guard case .failure(let error) = try await save(makeRecord()) else {
            Issue.record("Expected a tag-less record to conflict with the stored one")
            return
        }
        #expect(error is RecordConflictError)

        let overwrite = makeRecord()
        overwrite["s_01"] = "rewritten"
        try await database.modifyRecords(saving: [overwrite], deleting: [])
        #expect(database.records.count == 1)
        #expect(database.records.first?["s_01"] == "rewritten")

        let refetched = try #require(try await database.fetchRecord(id: id))
        _ = try await save(refetched).get()
    }

    @Test("A record fetched from the double carries the tag through its save loop")
    func fetchedRecordSavesRepeatedly() async throws {
        _ = try await save(makeRecord()).get()
        let fetched = try #require(try await database.fetchRecord(id: id))

        fetched["s_01"] = "second"
        _ = try await save(fetched).get()
        fetched["s_01"] = "third"
        _ = try await save(fetched).get()
        #expect(database.records.first?["s_01"] == "third")
    }
}
