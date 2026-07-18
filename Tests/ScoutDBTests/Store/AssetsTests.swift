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

@Suite("Assets")
struct AssetsTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(
            makeDefinition(
                entity: "report",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "dump", type: .asset, storage: .slot(.asset, "a_00")),
                    FieldDefinition(name: "screenshot", type: .asset, storage: .slot(.asset, "a_01")),
                ]))
    }

    @Test("Bytes written to an asset field are staged into a file")
    func staging() async throws {
        let payload = Data("stack trace".utf8)
        try await store.write(["name": .string("crash"), "dump": .bytes(payload)], entity: "report", uuid: "r-1")

        let item = try #require(database.records.first { $0.recordID.recordName == "r-1" })
        guard let asset = item["a_00"] as? CKAsset, let url = asset.fileURL else {
            Issue.record("Expected a staged asset URL")
            return
        }
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test("Several asset fields live side by side on one record")
    func multipleAssets() async throws {
        // Unique bytes per test: landed writes retire their content-addressed
        // staged files, so parallel tests must not share payloads.
        let dump = Data("minidump-\(UUID().uuidString)".utf8)
        let screenshot = Data("png-\(UUID().uuidString)".utf8)
        try await store.write(["dump": .bytes(dump), "screenshot": .bytes(screenshot)], entity: "report", uuid: "r-3")

        let record = try #require(try await store.read(entity: "report").first)
        #expect(try record.assetData(for: "dump") == dump)
        #expect(try record.assetData(for: "screenshot") == screenshot)
    }

    @Test("Export inlines asset bytes so the dump is self-contained")
    func exportInlinesAssetBytes() async throws {
        let payload = Data("dump-\(UUID().uuidString)".utf8)
        try await store.write(["name": .string("crash"), "dump": .bytes(payload)], entity: "report", uuid: "r-1")

        let dump = try await store.export(entity: "report")

        // The dump must carry the bytes, not a path into an ephemeral cache that
        // is useless on another machine or container.
        let decoded = try JSONDecoder().decode([EntityRecord].self, from: dump)
        #expect(decoded.first?.values["dump"] == .bytes(payload))

        // And a fresh store's import restores the asset from those bytes.
        let target = InMemoryDatabase()
        let targetRegistry = SchemaRegistry(database: target)
        try await targetRegistry.publish(
            makeDefinition(
                entity: "report",
                fields: [
                    FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "dump", type: .asset, storage: .slot(.asset, "a_00")),
                    FieldDefinition(name: "screenshot", type: .asset, storage: .slot(.asset, "a_01")),
                ]))
        let targetStore = EntityStore(database: target, registry: targetRegistry)
        #expect(try await targetStore.importRecords(dump, entity: "report") == 1)
        let record = try #require(try await targetStore.read(entity: "report").first)
        #expect(try record.assetData(for: "dump") == payload)
    }

    @Test("Asset data reads back through the record")
    func roundTrip() async throws {
        let payload = Data("roundtrip-\(UUID().uuidString)".utf8)
        try await store.write(["name": .string("crash"), "dump": .bytes(payload)], entity: "report", uuid: "r-1")

        let record = try #require(try await store.read(entity: "report").first)
        #expect(try record.assetData(for: "dump") == payload)
        #expect(try record.assetData(for: "name") == nil)
    }

    @Test("Staging is content-addressed")
    func contentAddressing() throws {
        let payload = Data("same bytes".utf8)
        let first = try EntityCoder.stage(payload)
        let second = try EntityCoder.stage(payload)
        let other = try EntityCoder.stage(Data("different".utf8))
        #expect(first == second)
        #expect(first != other)
    }

    @Test("Oversized payloads are rejected before upload")
    func oversize() throws {
        #expect(throws: SchemaError.invalidValue("asset")) {
            try EntityCoder.stage(Data(count: 9), limit: 8)
        }
    }

    @Test("Oversized staged files are rejected too")
    func oversizeFile() throws {
        guard case .asset(let url) = try EntityCoder.stage(Data(count: 9)) else {
            Issue.record("Expected a staged asset URL")
            return
        }
        #expect(throws: SchemaError.invalidValue("asset")) {
            try EntityCoder.validateAssetSize(at: url, limit: 8)
        }
    }

    @Test("A landed write retires its staged file")
    func stagedFileRetiredAfterWrite() async throws {
        let payload = Data("retire-\(UUID().uuidString)".utf8)
        guard case .asset(let staged) = try EntityCoder.stage(payload) else {
            Issue.record("Expected a staged asset URL")
            return
        }

        try await store.write(["dump": .bytes(payload)], entity: "report", uuid: "r-gc")

        #expect(!FileManager.default.fileExists(atPath: staged.path))
        // The bytes were uploaded during the save, so reads keep working.
        let record = try #require(try await store.read(entity: "report").first { $0.uuid == "r-gc" })
        #expect(try record.assetData(for: "dump") == payload)
    }

    @Test("A failed write keeps the staged file for the retry")
    func stagedFileSurvivesFailedWrite() async throws {
        let payload = Data("retry-\(UUID().uuidString)".utf8)
        guard case .asset(let staged) = try EntityCoder.stage(payload) else {
            Issue.record("Expected a staged asset URL")
            return
        }

        database.writeErrors = [CKError(.networkFailure)]
        await #expect(throws: CKError.self) {
            try await store.write(["dump": .bytes(payload)], entity: "report", uuid: "r-retry")
        }
        #expect(FileManager.default.fileExists(atPath: staged.path))

        // The retry reuses the staged file and retires it once it lands.
        try await store.write(["dump": .bytes(payload)], entity: "report", uuid: "r-retry")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let record = try #require(try await store.read(entity: "report").first { $0.uuid == "r-retry" })
        #expect(try record.assetData(for: "dump") == payload)
    }

    @Test("An update that stages new bytes retires them once it lands")
    func stagedFileRetiredAfterUpdate() async throws {
        try await store.write(["name": .string("crash")], entity: "report", uuid: "r-up")
        let payload = Data("update-\(UUID().uuidString)".utf8)
        guard case .asset(let staged) = try EntityCoder.stage(payload) else {
            Issue.record("Expected a staged asset URL")
            return
        }

        try await store.update(entity: "report", uuid: "r-up") { $0.values["dump"] = .bytes(payload) }

        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let record = try #require(try await store.read(entity: "report").first { $0.uuid == "r-up" })
        #expect(try record.assetData(for: "dump") == payload)
    }

    @Test("Sweep removes stale staged orphans and keeps fresh ones")
    func sweepStagedOrphans() throws {
        guard case .asset(let stale) = try EntityCoder.stage(Data("stale-\(UUID().uuidString)".utf8)),
            case .asset(let fresh) = try EntityCoder.stage(Data("fresh-\(UUID().uuidString)".utf8))
        else {
            Issue.record("Expected staged asset URLs")
            return
        }
        defer { try? FileManager.default.removeItem(at: fresh) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: stale.path)

        // Other suites stage files too, so only this test's own files are asserted.
        #expect(EntityStore.sweepStagedAssets(olderThan: 3_600) >= 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("A direct file URL still round-trips")
    func directURL() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-\(UUID().uuidString).bin")
        try Data("direct".utf8).write(to: url)

        try await store.write(["name": .string("crash"), "dump": .asset(url)], entity: "report", uuid: "r-2")
        let record = try #require(try await store.read(entity: "report").first)
        #expect(record.values["dump"] == .asset(url))
    }
}
