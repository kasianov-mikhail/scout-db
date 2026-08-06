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

@Suite("Vector cache")
struct VectorCacheTests {
    private func slot(_ name: String) -> CKRecord {
        CKRecord(recordType: VectorSlot.recordType, recordID: CKRecord.ID(recordName: name))
    }

    @Test("Eviction sheds the whole overflow at once, least recently used first")
    func evictionOrder() async {
        let cache = VectorCache(limit: 2)
        for name in ["a", "b", "c"] {
            await cache.keep(slot(name))
        }
        #expect(await cache.record(CKRecord.ID(recordName: "a")) == nil)
        #expect(await cache.record(CKRecord.ID(recordName: "b")) != nil)

        await cache.keep(slot("d"))
        #expect(await cache.record(CKRecord.ID(recordName: "c")) == nil)
        #expect(await cache.record(CKRecord.ID(recordName: "b")) != nil)
        #expect(await cache.record(CKRecord.ID(recordName: "d")) != nil)
    }

    @Test("Eviction waits for ten percent overflow, then sheds back to the limit")
    func evictionHysteresis() async {
        let cache = VectorCache(limit: 20)
        for index in 0..<22 {
            await cache.keep(slot("k-\(index)"))
        }
        #expect(await cache.record(CKRecord.ID(recordName: "k-0")) != nil)

        await cache.keep(slot("k-22"))
        for index in 1..<4 {
            #expect(await cache.record(CKRecord.ID(recordName: "k-\(index)")) == nil)
        }
        #expect(await cache.record(CKRecord.ID(recordName: "k-4")) != nil)
    }
}
