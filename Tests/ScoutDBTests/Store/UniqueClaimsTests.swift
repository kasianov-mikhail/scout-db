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

@Suite("Unique claims")
struct UniqueClaimsTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(Self.makeBadgeDefinition())
    }

    static func makeBadgeDefinition(version: Int = 1, enforced: Bool = true) -> EntityDefinition {
        EntityDefinition(
            entity: "badge", version: version,
            fields: [
                FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "label", type: .string, storage: .slot(.string, "s_01")),
            ],
            enforcedKeys: enforced ? [["code"]] : nil)
    }

    private var claims: [CKRecord] {
        database.records.filter { $0.recordType == "UniqueClaim" }
    }

    @Test("A write that duplicates a claimed key is rejected")
    func duplicateRejected() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        #expect(claims.count == 1)
        #expect(claims.first?["owner"] as? String == "b-1")
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        }
        #expect(try await store.read(entity: "badge").map(\.uuid) == ["b-1"])
    }

    @Test("A sweep claims the key it moves and releases the one it left behind")
    func sweepReclaimsMovedKeys() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        #expect(try await store.query("badge").filter("code", .equals, "gold").update { $0.values["code"] = .string("silver") } == 1)

        #expect(claims.count == 1)
        #expect(claims.first?["owner"] as? String == "b-1")
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("silver")], entity: "badge", uuid: "b-2")
        }
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-3")
        #expect(claims.count == 2)
    }

    @Test("A sweep onto a key another record holds is rejected")
    func sweepRejectsContestedKey() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.write(["code": .string("silver")], entity: "badge", uuid: "b-2")

        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.query("badge").filter("code", .equals, "gold").update { $0.values["code"] = .string("silver") }
        }
        #expect(try await store.read(entity: "badge", filters: [.init(field: "code", op: .equals, value: .string("gold"))]).map(\.uuid) == ["b-1"])
    }

    @Test("Re-writing the holder keeps its claim and succeeds")
    func idempotentRewrite() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.write(["code": .string("gold"), "label": .string("first")], entity: "badge", uuid: "b-1")
        #expect(claims.count == 1)
    }

    @Test("A batch holding the same key twice is rejected before any claim lands")
    func inBatchDuplicate() async throws {
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(
                [
                    EntityWrite(values: ["code": .string("gold")], uuid: "b-1"),
                    EntityWrite(values: ["code": .string("gold")], uuid: "b-2"),
                ], entity: "badge")
        }
        #expect(claims.isEmpty)
    }

    @Test("A re-key claims the new value and frees the old one")
    func rekeyMovesTheClaim() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.update(entity: "badge", uuid: "b-1") { record in
            record.values["code"] = .string("silver")
        }
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("silver")], entity: "badge", uuid: "b-2")
        }
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-3")
        #expect(claims.count == 2)
    }

    @Test("An update that would take another record's key is rejected")
    func rekeyOntoTakenValue() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.write(["code": .string("silver")], entity: "badge", uuid: "b-2")
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.update(entity: "badge", uuid: "b-2") { record in
                record.values["code"] = .string("gold")
            }
        }
    }

    @Test("Deleting the holder releases its claim")
    func deleteReleases() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.delete(entity: "badge", uuid: "b-1")
        #expect(claims.isEmpty)
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
    }

    @Test("A restore re-claims its values, and fails once they are re-taken")
    func restoreReclaims() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.delete(entity: "badge", uuid: "b-1")
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.restore(entity: "badge", uuid: "b-1")
        }
        try await store.delete(entity: "badge", uuid: "b-2")
        _ = try await store.restore(entity: "badge", uuid: "b-1")
        #expect(claims.first?["owner"] as? String == "b-1")
    }

    @Test("A stale claim whose owner no longer holds the value is adopted")
    func staleClaimAdopted() async throws {
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        database.records.removeAll { $0.recordType == "Entity" && $0["uuid"] as? String == "b-1" }
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        #expect(claims.count == 1)
        #expect(claims.first?["owner"] as? String == "b-2")
    }

    private func racedClaim(owner: String, code: String) -> [String: Any] {
        let record = CKRecord(recordType: "UniqueClaim", recordID: UniqueClaim.recordID(entity: "badge", digest: "code=\(code)"))
        record["entity"] = "badge"
        record["key"] = "code"
        record["owner"] = owner
        return [CKRecordChangedErrorServerRecordKey: record]
    }

    @Test("A claim lost to CloudKit's own conflict error still reports the duplicate")
    func rawConflictRejectsDuplicate() async throws {
        database.rawConflictErrors = true
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        database.records.removeAll { $0.recordType == "UniqueClaim" }
        database.writeErrors = [CKError(.serverRecordChanged, userInfo: racedClaim(owner: "b-1", code: "gold"))]

        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        }
        #expect(try await store.read(entity: "badge").map(\.uuid) == ["b-1"])
    }

    @Test("A claim lost to CloudKit's own conflict error still adopts an orphaned claim")
    func rawConflictAdoptsOrphanedClaim() async throws {
        database.rawConflictErrors = true
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        database.records.removeAll { $0.recordType == "UniqueClaim" || $0["uuid"] as? String == "b-1" }
        database.writeErrors = [CKError(.serverRecordChanged, userInfo: racedClaim(owner: "b-1", code: "gold"))]

        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-2")
        #expect(claims.count == 1)
        #expect(claims.first?["owner"] as? String == "b-2")
    }

    @Test("An enforced write fails offline instead of queueing a false success")
    func offlineWriteFails() async throws {
        let cache = OfflineCache(backing: database)
        let offlineStore = EntityStore(database: cache, registry: SchemaRegistry(database: cache))
        try await offlineStore.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        database.errors = [CKError(.networkUnavailable)]
        await #expect(throws: CKError.self) {
            try await offlineStore.write(["code": .string("silver")], entity: "badge", uuid: "b-2")
        }
        #expect(cache.pendingWrites == 0)
    }

    @Test("Backfill claims existing records and surfaces genuine duplicates")
    func backfill() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        let store = EntityStore(database: database, registry: registry)
        try await registry.publish(Self.makeBadgeDefinition(version: 1, enforced: false))
        try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-1")
        try await store.write(["code": .string("silver")], entity: "badge", uuid: "b-2")

        try await registry.publish(Self.makeBadgeDefinition(version: 2, enforced: true))
        let migrator = Migrator(database: database, registry: registry)
        #expect(try await migrator.backfillClaims(entity: "badge") == 2)
        #expect(database.records.filter { $0.recordType == "UniqueClaim" }.count == 2)

        await #expect(throws: SchemaError.duplicateKey(fields: ["code"])) {
            try await store.write(["code": .string("gold")], entity: "badge", uuid: "b-3")
        }
        #expect(try await migrator.backfillClaims(entity: "badge") == 2)
    }

    @Test("Reaping an expired record releases the claim it held")
    func reapReleasesClaims() async throws {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        let store = EntityStore(database: database, registry: registry)
        try await registry.publish(
            EntityDefinition(
                entity: "session", version: 1,
                fields: [
                    FieldDefinition(name: "code", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                ], envelopeDate: "date", enforcedKeys: [["code"]], ttl: 3_600))

        try await store.write(["code": .string("gold"), "date": .date(Date(timeIntervalSince1970: 1_000))], entity: "session", uuid: "s-1")
        #expect(database.records.filter { $0.recordType == "UniqueClaim" }.count == 1)

        #expect(try await store.reap(entity: "session", asOf: Date(timeIntervalSince1970: 50_000)) == 1)
        #expect(database.records.filter { $0.recordType == "UniqueClaim" }.isEmpty)
    }

    @Test("Releasing more claims than one batch holds splits the delete")
    func releaseChunksClaims() async throws {
        let backing = InMemoryDatabase()
        let probe = BatchProbe(backing: backing)
        let registry = SchemaRegistry(database: probe)
        let store = EntityStore(database: probe, registry: registry)
        try await registry.publish(Self.makeBadgeDefinition())

        try await store.write((0..<401).map { EntityWrite(values: ["code": .string("c-\($0)")], uuid: "b-\($0)") }, entity: "badge")
        probe.reset()

        #expect(try await store.deleteAll(entity: "badge") == 401)
        #expect(probe.deleteBatches.allSatisfy { $0 <= 400 })
        #expect(probe.deleteBatches.reduce(0, +) == 401)
    }
}
