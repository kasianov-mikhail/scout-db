//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func extremum(in cell: GridCell, using definition: EntityDefinition) async throws -> Double? {
        guard let metric = cell.view.metric, metric.kind != .sum else {
            return nil
        }
        var filters: [Filter] = []

        if let groupBy = cell.view.groupBy {
            guard let field = definition.field(named: groupBy, at: definition.version) else {
                return nil
            }
            guard let parse = field.type.canonicalParser, let value = parse(cell.group) else {
                return nil
            }

            filters.append(Filter(field: groupBy, op: .equals, value: value))
        }

        let scalars = try await read(
            entity: definition.entity,
            filters: filters,
            fields: [metric.field]
        )
        .compactMap {
            $0.values[metric.field]?.scalar
        }

        return metric.kind == .min ? scalars.min() : scalars.max()
    }
}
