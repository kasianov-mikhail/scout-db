//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct DefinitionCodeGenerator {
    public init() {}

    public func source(for definition: EntityDefinition) -> String {
        let typeName = camel(definition.entity, capitalized: true)
        let fields = definition.fields(at: definition.version)

        var lines = ["struct \(typeName) {"]
        for field in fields {
            lines.append("    var \(camel(field.name)): \(swiftType(of: field.type))?")
        }
        lines.append("")
        lines.append("    init(record: EntityRecord) {")
        for field in fields {
            if field.type == .location || field.type == .asset {
                lines.append("        \(camel(field.name)) = record.values[\"\(field.name)\"]")
            } else {
                lines.append("        \(camel(field.name)) = record[\"\(field.name)\"]")
            }
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func swiftType(of type: FieldType) -> String {
        switch type {
        case .string, .text: "String"
        case .int: "Int64"
        case .double: "Double"
        case .timestamp: "Date"
        case .bytes: "Data"
        case .reference: "String"
        case .stringList: "[String]"
        case .intList: "[Int64]"
        case .doubleList: "[Double]"
        case .timestampList: "[Date]"
        case .locationList: "RecordValue"
        case .assetList: "RecordValue"
        case .location: "RecordValue"
        case .asset: "RecordValue"
        }
    }

    private func camel(_ name: String, capitalized: Bool = false) -> String {
        let parts = name.split(separator: "_").map(String.init)
        guard let first = parts.first else { return name }
        let head = capitalized ? first.capitalized : first.lowercased()
        return head + parts.dropFirst().map(\.capitalized).joined()
    }
}
