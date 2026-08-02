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

@Suite("Contract: sync")
struct SyncContractTests {
    @Test("A stale conditional save loses to the server copy")
    func staleConditionalSave() async throws {
        try await withContract { f in
            let entity = try await f.publishOrder()
            try await f.store.write([EntityWrite(values: orderValues(product: "base"), uuid: "cas-1")], entity: entity)
            try await eventually { try await ReadOperation(store: f.store, entity: entity).read().count == 1 }

            let id = CKRecord.ID(recordName: "cas-1")
            let fresh = try #require(try await f.database.fetchRecord(id: id))
            let stale = try #require(try await f.database.fetchRecord(id: id))

            fresh["s_00"] = "winner"
            for (_, result) in try await f.database.saveIfUnchanged([fresh]) {
                _ = try result.get()
            }

            stale["s_00"] = "loser"
            let results = try await f.database.saveIfUnchanged([stale])
            #expect(
                results.contains { _, result in
                    guard case .failure(let error) = result else {
                        return false
                    }
                    return error is RecordConflictError || (error as? CKError)?.code == .serverRecordChanged
                }
            )
        }
    }
}
