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

@Suite("InMemory concurrency")
struct InMemoryConcurrencyTests {
    let database = InMemoryDatabase()

    private func makeRecord(_ index: Int) -> CKRecord {
        CKRecord(recordType: "Thing", recordID: CKRecord.ID(recordName: "t-\(index)"))
    }

    @Test("Concurrent writes land whole")
    func concurrentWrites() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    _ = try await self.database.saveIfUnchanged([self.makeRecord(index)])
                }
                group.addTask {
                    try await self.database.modifyRecords(saving: [self.makeRecord(1_000 + index)], deleting: [])
                }
            }
            try await group.waitForAll()
        }

        #expect(database.records.count == 400)
        #expect(Set(database.records.map(\.recordID)).count == 400)
    }

    @Test("A read running against concurrent writes sees a whole store")
    func concurrentReadsAndWrites() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    _ = try await self.database.saveIfUnchanged([self.makeRecord(index)])
                }
                group.addTask {
                    _ = try await self.database.fetchRecords(ids: (0..<100).map { CKRecord.ID(recordName: "t-\($0)") })
                }
            }
            try await group.waitForAll()
        }

        #expect(database.records.count == 100)
    }
}
