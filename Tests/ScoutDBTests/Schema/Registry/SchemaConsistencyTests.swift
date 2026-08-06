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

@Suite("Schema consistency")
struct SchemaConsistencyTests {
    static let schema = try! String(contentsOf: schemaURL(), encoding: .utf8)

    @Test("Every pool declares exactly its capacity, contiguously", arguments: FieldType.allCases)
    func poolCapacity(pool: FieldType) throws {
        let slots = Self.fields(of: "Entity").filter { $0.name.hasPrefix("\(pool.slotPrefix)_") }
        #expect(slots.count == pool.capacity)

        let indices = slots.compactMap { Int($0.name.dropFirst(pool.slotPrefix.count + 1)) }.sorted()
        #expect(indices == Array(0..<pool.capacity))
    }

    @Test("Pool slots carry the modifiers the store relies on", arguments: FieldType.allCases)
    func poolModifiers(pool: FieldType) throws {
        let expected =
            switch pool {
            case .string: "STRING QUERYABLE SORTABLE"
            case .text: "STRING QUERYABLE SEARCHABLE SORTABLE"
            case .int: "INT64 QUERYABLE SORTABLE"
            case .double: "DOUBLE QUERYABLE SORTABLE"
            case .timestamp: "TIMESTAMP QUERYABLE SORTABLE"
            case .bytes: "BYTES QUERYABLE"
            case .reference: "REFERENCE QUERYABLE"
            case .stringList: "LIST<STRING> QUERYABLE"
            case .intList: "LIST<INT64> QUERYABLE"
            case .doubleList: "LIST<DOUBLE> QUERYABLE"
            case .timestampList: "LIST<TIMESTAMP> QUERYABLE"
            }
        let slots = Self.fields(of: "Entity").filter { $0.name.hasPrefix("\(pool.slotPrefix)_") }
        #expect(slots.allSatisfy { $0.spec == expected })
    }

    @Test("Entity carries the envelope the coder stamps")
    func itemEnvelope() {
        let names = Set(Self.fields(of: "Entity").map(\.name))
        for field in ["entity", "schema_version", "uuid", "payload"] {
            #expect(names.contains(field), "Entity is missing '\(field)'")
        }
    }

    @Test("Vector cells match the aggregator addressing")
    func vectorCells() {
        let cells = Self.fields(of: "Vector").filter { $0.name.hasPrefix("c_") }
        #expect(cells.map(\.name) == VectorSlot.cellKeys)
        #expect(cells.allSatisfy { $0.spec == "DOUBLE QUERYABLE SORTABLE" })

        let names = Set(Self.fields(of: "Vector").map(\.name))
        for field in ["entity", "aggregate", "group_key", "date", "schema_version"] {
            #expect(names.contains(field), "Vector is missing '\(field)'")
        }
    }

    @Test("The registry files its descriptors in Entity")
    func metaFields() {
        #expect(SchemaDescriptorEntry.recordType == "Entity")

        let fields = Dictionary(
            Self.fields(of: "Entity").map { ($0.name, $0.spec) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(fields["s_00"] == "STRING QUERYABLE SORTABLE")
        #expect(fields["s_01"] == "STRING QUERYABLE SORTABLE")
        #expect(fields["b_00"] == "BYTES QUERYABLE")
        #expect(fields["schema_version"] == "INT64 QUERYABLE SORTABLE")
    }

    @Test("The change feed cursor is queryable", arguments: ["Entity", "Vector"])
    func modTimeIndexed(type: String) {
        let modTime = Self.fields(of: type).first { $0.name == "\"___modTime\"" }
        #expect(modTime?.spec == "TIMESTAMP QUERYABLE SORTABLE")
    }

    private static func fields(of recordType: String) -> [(name: String, spec: String)] {
        guard let start = schema.range(of: "RECORD TYPE \(recordType) (") else {
            return []
        }
        guard let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex) else {
            return []
        }

        return schema[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(","), !trimmed.hasPrefix("GRANT") else {
                return nil
            }
            let parts = trimmed.dropLast().split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                return nil
            }
            return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func schemaURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Schema")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue
            {
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
