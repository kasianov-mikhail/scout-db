//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
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

        let item = try #require(database.records.first { $0.recordID == "r-1" })
        guard case .asset(let url)? = item.fields["a_00"] else {
            Issue.record("Expected a staged asset URL")
            return
        }
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test("Several asset fields live side by side on one record")
    func multipleAssets() async throws {
        let dump = Data("minidump".utf8)
        let screenshot = Data("png".utf8)
        try await store.write(["dump": .bytes(dump), "screenshot": .bytes(screenshot)], entity: "report", uuid: "r-3")

        let record = try #require(try await store.read(entity: "report").first)
        #expect(try record.assetData(for: "dump") == dump)
        #expect(try record.assetData(for: "screenshot") == screenshot)
    }

    @Test("Asset data reads back through the record")
    func roundTrip() async throws {
        let payload = Data("minidump".utf8)
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

    @Test("A direct file URL still round-trips")
    func directURL() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-\(UUID().uuidString).bin")
        try Data("direct".utf8).write(to: url)

        try await store.write(["name": .string("crash"), "dump": .asset(url)], entity: "report", uuid: "r-2")
        let record = try #require(try await store.read(entity: "report").first)
        #expect(record.values["dump"] == .asset(url))
    }
}
