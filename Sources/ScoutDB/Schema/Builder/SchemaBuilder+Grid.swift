//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    static func name(_ metric: String?, of field: String?, by group: String?) -> String {
        var parts = [metric, field, group.map { "by_\($0)" }].compactMap { $0 }
        if parts.isEmpty {
            parts = ["by_all"]
        }
        return parts.joined(separator: "_")
    }

    static func merge(
        _ declared: [AggregateDefinition], onto inherited: [AggregateDefinition], keeping active: Set<String>
    )
        -> [AggregateDefinition]
    {
        let byName = Dictionary(declared.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        let superseded = declared.map(\.groupBy)
        var merged = inherited.compactMap { aggregate -> AggregateDefinition? in
            if let replacement = byName[aggregate.name] {
                return replacement
            }
            return aggregate.metricField == nil && superseded.contains(aggregate.groupBy) ? nil : aggregate
        }
        merged += declared.filter { aggregate in !inherited.contains { $0.name == aggregate.name } }
        return merged.filter { aggregate in
            let fields = [aggregate.groupBy, aggregate.metricField].compactMap { $0 }
            return fields.allSatisfy(active.contains)
        }
    }

    static func grid(over fields: [FieldDefinition], declaring declared: [AggregateDefinition]) -> [AggregateDefinition]
    {
        var taken = Set(declared.map(\.name))
        var counted = Set(declared.compactMap(\.groupBy))
        var grid = declared

        for field in fields where Self.groupable(field) {
            guard taken.insert("by_\(field.name)").inserted, counted.insert(field.name).inserted else {
                continue
            }
            grid.append(AggregateDefinition(name: "by_\(field.name)", groupBy: field.name))
        }
        return grid
    }

    static func groupable(_ field: FieldDefinition) -> Bool {
        guard case .slot = field.storage, field.ungrouped != true else {
            return false
        }
        return [.string, .reference, .int, .double].contains(field.type)
    }
}
