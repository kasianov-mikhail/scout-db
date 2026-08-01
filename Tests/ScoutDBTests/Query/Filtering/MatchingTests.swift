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

@Suite("Matching")
struct MatchingTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(
            makeDefinition(
                entity: "note",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(name: "title_fold", type: .string, storage: .slot(.string, "s_02"), derived: Derivation(source: "title", transform: .fold)),
                    FieldDefinition(name: "body", type: .text, storage: .slot(.text, "x_00")),
                    FieldDefinition(name: "summary", type: .text, storage: .slot(.text, "x_01")),
                    FieldDefinition(name: "memo", type: .string, storage: .payload),
                ]))
        try await store.write(["title": .string("Hello World"), "body": .string("The quick brown fox"), "memo": .string("keep")], entity: "note", uuid: "n-1")
        try await store.write(["title": .string("Café Crème"), "body": .string("Lazy dog sleeps")], entity: "note", uuid: "n-2")
    }

    private func read(_ field: String, _ op: EntityStore.Match, _ value: String) async throws -> [String] {
        let records = try await store.read(entity: "note", filters: [EntityStore.Filter(field: field, op: op, value: .string(value))])
        return records.map(\.uuid)
    }

    @Test("CONTAINS on a string is a client-side substring check")
    func substring() async throws {
        #expect(try await read("title", .contains, "lo Wo") == ["n-1"])
        #expect(try await read("title", .contains, "xyz") == [])
    }

    @Test("A slot the schema cannot sort is refused up front")
    func unsortableSlots() async throws {
        try await registry.publish(
            makeDefinition(
                entity: "shot",
                fields: [
                    FieldDefinition(name: "blob", type: .bytes, storage: .slot(.bytes, "b_00")),
                    FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                ]))
        let definition = try await registry.definition(for: "shot")

        for field in ["blob", "tags"] {
            #expect(throws: SchemaError.invalidValue(field)) {
                _ = try store.serverSort([EntityStore.Sort(field: field)], using: definition)
            }
        }

        #expect(try store.split([EntityStore.Filter(field: "blob", op: .isNull, value: .int(0))], entity: "shot", using: definition).client.count == 1)
    }

    @Test("Full-text search matches whole tokens in searchable fields")
    func search() async throws {
        #expect(try await read("body", .search, "brown") == ["n-1"])
        #expect(try await read("body", .search, "brow") == [])
    }

    @Test("Search is scoped to the named field, not the whole record")
    func fieldScopedSearch() async throws {
        try await store.write(
            ["title": .string("Notes"), "body": .string("nothing here"), "summary": .string("fox sighting")], entity: "note", uuid: "n-3")
        #expect(try await read("body", .search, "fox") == ["n-1"])
        #expect(try await read("summary", .search, "fox") == ["n-3"])

        #expect(try await read("body", .search, "quick fox") == ["n-1"])
        #expect(try await read("body", .search, "quick sighting") == [])
    }

    @Test("Search is rejected on non-searchable fields")
    func searchRequiresText() async throws {
        await #expect(throws: SchemaError.invalidValue("title")) {
            _ = try await read("title", .search, "hello")
        }
    }

    @Test("Case- and diacritic-insensitive match through the folded shadow")
    func folded() async throws {
        #expect(try await read("title_fold", .equals, "cafe creme") == ["n-2"])
        #expect(try await read("title_fold", .equals, "CAFE CREME".folded) == ["n-2"])
    }

    @Test("IS NULL and IS NOT NULL work on payload fields")
    func nullness() async throws {
        #expect(try await read("memo", .isNotNull, "") == ["n-1"])
        #expect(try await read("memo", .isNull, "") == ["n-2"])
    }
}
