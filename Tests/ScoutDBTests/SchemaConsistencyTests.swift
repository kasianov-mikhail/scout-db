//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

/// Pins the frozen `Schema` file to the code that interprets it.
///
/// Once the
/// schema ships to Production it is append-only forever, so any drift between
/// the declared slots and `Pool.capacity`, the envelope the coder stamps, or
/// the grid cells the aggregator addresses is a released bug.
///
@Suite("Schema consistency")
struct SchemaConsistencyTests {
    static let schema = try! String(contentsOf: schemaURL(), encoding: .utf8)

    @Test("Every pool declares exactly its capacity, contiguously", arguments: Pool.allCases)
    func poolCapacity(pool: Pool) throws {
        let slots = Self.fields(of: "Item").filter { $0.name.hasPrefix("\(pool.rawValue)_") }
        #expect(slots.count == pool.capacity)

        let indices = slots.compactMap { Int($0.name.dropFirst(pool.rawValue.count + 1)) }.sorted()
        #expect(indices == Array(0..<pool.capacity))
    }

    @Test("Pool slots carry the modifiers the store relies on", arguments: Pool.allCases)
    func poolModifiers(pool: Pool) throws {
        let expected =
            switch pool {
            case .string: "STRING QUERYABLE SORTABLE"
            case .text: "STRING QUERYABLE SEARCHABLE SORTABLE"
            case .int: "INT64 QUERYABLE SORTABLE"
            case .double: "DOUBLE QUERYABLE SORTABLE"
            case .timestamp: "TIMESTAMP QUERYABLE SORTABLE"
            case .bytes: "BYTES QUERYABLE"
            case .location: "LOCATION QUERYABLE"
            case .reference: "REFERENCE QUERYABLE"
            case .asset: "ASSET"
            case .stringList: "LIST<STRING> QUERYABLE"
            case .intList: "LIST<INT64> QUERYABLE"
            case .doubleList: "LIST<DOUBLE> QUERYABLE"
            case .timestampList: "LIST<TIMESTAMP> QUERYABLE"
            case .locationList: "LIST<LOCATION> QUERYABLE"
            case .assetList: "LIST<ASSET>"
            }
        let slots = Self.fields(of: "Item").filter { $0.name.hasPrefix("\(pool.rawValue)_") }
        #expect(slots.allSatisfy { $0.spec == expected })
    }

    @Test("Item carries the envelope the coder stamps")
    func itemEnvelope() {
        let names = Set(Self.fields(of: "Item").map(\.name))
        for field in ["entity", "schema_version", "uuid", "deleted", "expires", "payload"] {
            #expect(names.contains(field), "Item is missing '\(field)'")
        }
    }

    @Test("GridItem cells match the aggregator addressing")
    func gridCells() {
        let fields = Self.fields(of: "GridItem")
        #expect(fields.filter { $0.name.hasPrefix("c_") }.count == 64)
        #expect(fields.filter { $0.name.hasPrefix("f_") }.count == 64)
        let names = Set(fields.map(\.name))
        for field in ["entity", "view", "group_key", "date", "schema_version"] {
            #expect(names.contains(field), "GridItem is missing '\(field)'")
        }
    }

    @Test("Meta carries the registry fields")
    func metaFields() {
        let names = Set(Self.fields(of: "Meta").map(\.name))
        #expect(names.isSuperset(of: ["entity", "entity_version", "definition", "status"]))
    }

    @Test("The change feed cursor is queryable", arguments: ["Item", "GridItem", "Meta"])
    func modTimeIndexed(type: String) {
        let modTime = Self.fields(of: type).first { $0.name == "\"___modTime\"" }
        #expect(modTime?.spec == "TIMESTAMP QUERYABLE SORTABLE")
    }

    private static func fields(of recordType: String) -> [(name: String, spec: String)] {
        guard let start = schema.range(of: "RECORD TYPE \(recordType) (") else { return [] }
        guard let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex) else { return [] }

        return schema[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(","), !trimmed.hasPrefix("GRANT") else { return nil }
            let parts = trimmed.dropLast().split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func schemaURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Schema")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw SchemaV2Error.fileNotFound
    }

    private enum SchemaV2Error: Error {
        case fileNotFound
    }
}
