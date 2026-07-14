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

@Suite("Schema export")
struct SchemaExportTests {
    let database = InMemoryDatabase()

    @Test("Exported definitions round-trip through the codegen toolchain")
    func exportRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scout-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())

        // A fresh registry has an empty cache: the export must preload the
        // active set from the database, not echo local state.
        let files = try await SchemaRegistry(database: database).exportDefinitions(to: directory)
        #expect(files.map(\.lastPathComponent) == ["purchase.entity.json"])

        let data = try Data(contentsOf: try #require(files.first))
        let decoded = try JSONDecoder().decode(EntityDefinition.self, from: data)
        #expect(decoded == makePurchaseDefinition())

        // The exported file is exactly what the codegen CLI and plugin consume.
        let source = try DefinitionCodeGenerator().source(forJSON: data)
        #expect(source.contains("struct Purchase"))
    }

    @Test("Exports are byte-stable across runs")
    func stableOutput() async throws {
        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        let definition = try await registry.definition(for: "purchase")
        #expect(try definition.exportedJSON() == definition.exportedJSON())
    }

    @Test("A retired entity stays out of the export")
    func retiredEntityExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scout-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = SchemaRegistry(database: database)
        try await registry.publish(makePurchaseDefinition())
        try await registry.publish(
            makeDefinition(
                entity: "draft", version: 1,
                fields: [FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"))]))
        try await registry.retire(entity: "draft")

        let files = try await SchemaRegistry(database: database).exportDefinitions(to: directory)
        #expect(files.map(\.lastPathComponent) == ["purchase.entity.json"])
    }
}
