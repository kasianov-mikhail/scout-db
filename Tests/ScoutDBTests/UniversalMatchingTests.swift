//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Universal matching")
struct UniversalMatchingTests {
    let database = InMemoryDatabase()
    let store: UniversalStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = UniversalStore(database: database, registry: registry)
        try await registry.publish(
            makeDefinition(
                entity: "note",
                fields: [
                    FieldDefinition(name: "title", type: .string, storage: .slot(.string, "s_00")),
                    FieldDefinition(
                        name: "title_rev", type: .string, storage: .slot(.string, "s_01"), derived: Derivation(source: "title", transform: .reversed)),
                    FieldDefinition(name: "title_fold", type: .string, storage: .slot(.string, "s_02"), derived: Derivation(source: "title", transform: .fold)),
                    FieldDefinition(
                        name: "title_grams", type: .stringList, storage: .slot(.stringList, "ls_00"), derived: Derivation(source: "title", transform: .ngrams)),
                    FieldDefinition(name: "body", type: .text, storage: .slot(.text, "x_00")),
                    FieldDefinition(name: "memo", type: .string, storage: .payload),
                ]))
        try await store.write(["title": .string("Hello World"), "body": .string("The quick brown fox"), "memo": .string("keep")], entity: "note", uuid: "n-1")
        try await store.write(["title": .string("Café Crème"), "body": .string("Lazy dog sleeps")], entity: "note", uuid: "n-2")
    }

    private func read(_ field: String, _ op: UniversalStore.Match, _ value: String) async throws -> [String] {
        let records = try await store.read(entity: "note", filters: [UniversalStore.Filter(field: field, op: op, value: .string(value))])
        return records.map(\.uuid)
    }

    @Test("ENDSWITH runs server-side through the reversed shadow slot")
    func endsWithShadow() async throws {
        #expect(try await read("title", .endsWith, "World") == ["n-1"])
        let item = try #require(database.records.first { $0.recordID == "n-1" })
        #expect(item["s_01"] == "dlroW olleH")
    }

    @Test("ENDSWITH falls back to a client-side matcher without a shadow")
    func endsWithFallback() async throws {
        #expect(try await read("body", .endsWith, "fox") == ["n-1"])
    }

    @Test("CONTAINS on a string is a client-side substring check")
    func substring() async throws {
        #expect(try await read("title", .contains, "lo Wo") == ["n-1"])
        #expect(try await read("title", .contains, "xyz") == [])
    }

    @Test("The ngram shadow materializes trigrams of the folded source")
    func ngramShadow() async throws {
        let item = try #require(database.records.first { $0.recordID == "n-1" })
        let trigrams: [String] = try #require(item["ls_00"])
        #expect(trigrams.contains("hel"))
        #expect(trigrams.contains("o w"))
        #expect(!trigrams.contains("Hel"))
    }

    @Test("Substring search narrows server-side through trigram predicates")
    func ngramPrefilter() async throws {
        let definition = try await registry.definition(for: "note")
        let filter = UniversalStore.Filter(field: "title", op: .contains, value: .string("lo Wo"))
        let (server, client) = try store.split([filter], entity: "note", using: definition)

        let trigramFilters = server.filter { $0.field == "ls_00" && $0.op == .contains }
        #expect(trigramFilters.count == UniversalCoder.trigrams(of: "lo wo").count)
        #expect(client == [filter])
    }

    @Test("Short needles skip the trigram prefilter")
    func shortNeedle() async throws {
        #expect(try await read("title", .contains, "lo") == ["n-1"])
        let definition = try await registry.definition(for: "note")
        let filter = UniversalStore.Filter(field: "title", op: .contains, value: .string("lo"))
        let (server, _) = try store.split([filter], entity: "note", using: definition)
        #expect(server.filter { $0.field == "ls_00" }.count == 0)
    }

    @Test("Wildcard literals feed the trigram prefilter")
    func likePrefilter() async throws {
        #expect(try await read("title", .like, "H*World") == ["n-1"])
        let definition = try await registry.definition(for: "note")
        let filter = UniversalStore.Filter(field: "title", op: .like, value: .string("H*World"))
        let (server, _) = try store.split([filter], entity: "note", using: definition)
        #expect(server.filter { $0.field == "ls_00" }.count == UniversalCoder.trigrams(of: "world").count)
    }

    @Test("LIKE supports * and ? wildcards")
    func like() async throws {
        #expect(try await read("title", .like, "H*World") == ["n-1"])
        #expect(try await read("title", .like, "H?llo*") == ["n-1"])
        #expect(try await read("title", .like, "H?World") == [])
    }

    @Test("MATCHES applies a whole-string regular expression")
    func regex() async throws {
        #expect(try await read("title", .matches, "H.*d") == ["n-1"])
        #expect(try await read("title", .matches, "Hello") == [])
    }

    @Test("Full-text search matches whole tokens in searchable fields")
    func search() async throws {
        #expect(try await read("body", .search, "brown") == ["n-1"])
        #expect(try await read("body", .search, "brow") == [])
    }

    @Test("Search is rejected on non-searchable fields")
    func searchRequiresText() async throws {
        await #expect(throws: UniversalSchemaError.invalidValue("title")) {
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
