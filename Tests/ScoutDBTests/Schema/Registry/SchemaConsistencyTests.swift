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

    static let heldPools = [
        "g": "LOCATION QUERYABLE", "a": "ASSET", "lg": "LIST<LOCATION> QUERYABLE", "la": "LIST<ASSET>",
    ]

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
            case .referenceList: "LIST<REFERENCE> QUERYABLE"
            case .bytesList: "LIST<BYTES> QUERYABLE"
            }
        let slots = Self.fields(of: "Entity").filter { $0.name.hasPrefix("\(pool.slotPrefix)_") }
        #expect(slots.allSatisfy { $0.spec == expected })
    }

    @Test("The payload pool declares exactly its capacity, contiguously")
    func payloadCapacity() {
        let slots = Self.fields(of: "Entity").filter { $0.name.hasPrefix("\(PayloadPool.slotPrefix)_") }
        #expect(slots.count == PayloadPool.capacity)

        let indices = slots.compactMap { PayloadPool.slotIndex($0.name) }.sorted()
        #expect(indices == Array(0..<PayloadPool.capacity))
        #expect(slots.allSatisfy { $0.spec == "BYTES" }, "Nothing filters a payload slot server-side")
    }

    @Test("The pools spend the field budget whole and no further")
    func fieldBudget() {
        let columns = Self.fields(of: "Entity").filter { !$0.name.hasPrefix("\"___") }
        #expect(columns.count == 256, "CloudKit caps a record type at 256 fields")

        let allocatable = FieldType.allCases.map(\.capacity).reduce(PayloadPool.capacity, +)
        let held = columns.filter { column in
            Self.heldPools.keys.contains { column.name.hasPrefix("\($0)_") }
        }
        #expect(allocatable + held.count == columns.count, "Every column is either allocatable or held for later")
    }

    @Test("The location and asset pools stay declared, at a token of their old size")
    func heldPools() {
        for (prefix, spec) in Self.heldPools {
            let slots = Self.fields(of: "Entity").filter { $0.name.hasPrefix("\(prefix)_") }
            #expect(slots.count == 4, "The '\(prefix)' pool holds a token of the budget for a type to claim")
            #expect(slots.allSatisfy { $0.spec == spec })
        }
    }

    @Test("Entity carries the envelope the coder stamps")
    func itemEnvelope() {
        let names = Set(Self.fields(of: "Entity").map(\.name))
        for field in [Envelope.entity, Envelope.version] {
            #expect(names.contains(field), "Entity is missing '\(field)'")
        }

        let recordID = Self.fields(of: "Entity").first { $0.name == "\"\(Envelope.uuid)\"" }
        #expect(recordID?.spec == "REFERENCE QUERYABLE SORTABLE", "A page breaks its ties on the record name")
    }

    @Test("The record's creator is queryable")
    func creatorIndexed() {
        let creator = Self.fields(of: "Entity").first { $0.name == "\"___createdBy\"" }
        #expect(creator?.spec == "REFERENCE QUERYABLE", "A scan narrows to the caller's own records server-side")
    }

    @Test("Vector cells match the aggregator addressing")
    func vectorCells() {
        let cells = Self.fields(of: "Vector").filter { $0.name.hasPrefix("c_") }
        #expect(cells.map(\.name) == (0..<256).map { String(format: "c_%03d", $0) })
        #expect(cells.map(\.name).starts(with: VectorSlot.cellKeys))
        #expect(
            cells.allSatisfy { $0.spec == "DOUBLE" },
            "A cell is reached through the record name, so no query ever filters or sorts one"
        )

        let named = Self.fields(of: "Vector").filter { !$0.name.hasPrefix("c_") && !$0.name.hasPrefix("\"___") }
        #expect(named.isEmpty, "A vector is addressed by name and carries nothing but cells")
    }

    @Test("The registry files its descriptors in Entity")
    func metaFields() {
        #expect(SchemaDescriptorEntry.recordType == "Entity")

        let fields = Dictionary(
            Self.fields(of: "Entity").map { ($0.name, $0.spec) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(fields["s_01"] == "STRING QUERYABLE SORTABLE")
        #expect(fields["s_02"] == "STRING QUERYABLE SORTABLE")
        #expect(fields["b_00"] == "BYTES QUERYABLE")
        #expect(fields[Envelope.version] == "INT64 QUERYABLE SORTABLE")
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
