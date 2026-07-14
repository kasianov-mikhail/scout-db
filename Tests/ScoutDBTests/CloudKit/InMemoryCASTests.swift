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

/// The double's change-tag conditional-save semantics, mirroring the server's.
@Suite("InMemory CAS")
struct InMemoryCASTests {
    let database = InMemoryDatabase()
    let id = CKRecord.ID(recordName: "t-1")

    private func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: "Thing", recordID: id)
        record["s_00"] = "base"
        return record
    }

    @Test("A stale single-record save conflicts with the server copy")
    func staleSaveConflicts() async throws {
        _ = try await database.save(makeRecord())
        let fresh = try #require(try await database.fetchRecord(id: id))
        let stale = try #require(try await database.fetchRecord(id: id))

        fresh["s_00"] = "winner"
        _ = try await database.save(fresh)

        stale["s_00"] = "loser"
        do {
            _ = try await database.save(stale)
            Issue.record("Expected a RecordConflictError")
        } catch let conflict as RecordConflictError {
            #expect(conflict.serverRecord["s_00"] == "winner")
        }
        #expect(database.records.first?["s_00"] == "winner")
    }

    @Test("A batch conditional save fails only its stale records")
    func batchFailsOnlyStale() async throws {
        _ = try await database.save(makeRecord())
        let stale = try #require(try await database.fetchRecord(id: id))
        let fresh = try #require(try await database.fetchRecord(id: id))
        fresh["s_00"] = "winner"
        _ = try await database.save(fresh)

        stale["s_00"] = "loser"
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
        _ = try await database.save(makeRecord())

        // A second fresh record with the same id has no tag to compare.
        await #expect(throws: RecordConflictError.self) {
            _ = try await database.save(makeRecord())
        }

        // The batch path mirrors .allKeys — last write wins, tag advances.
        let overwrite = makeRecord()
        overwrite["s_00"] = "rewritten"
        try await database.modifyRecords(saving: [overwrite], deleting: [])
        #expect(database.records.count == 1)
        #expect(database.records.first?["s_00"] == "rewritten")

        let refetched = try #require(try await database.fetchRecord(id: id))
        _ = try await database.save(refetched)
    }

    @Test("A record fetched from the double carries the tag through its save loop")
    func fetchedRecordSavesRepeatedly() async throws {
        _ = try await database.save(makeRecord())
        let fetched = try #require(try await database.fetchRecord(id: id))

        // Each landed save stamps a new tag on the instance it stored, so the
        // caller can keep editing and saving the same record, like with the
        // record a real save returns.
        fetched["s_00"] = "second"
        _ = try await database.save(fetched)
        fetched["s_00"] = "third"
        _ = try await database.save(fetched)
        #expect(database.records.first?["s_00"] == "third")
    }
}
