//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func extremum(in range: GridAggregator.CellRange, using definition: EntityDefinition) async throws -> Double? {
        guard let metric = range.view.metric, metric.kind != .sum else {
            return nil
        }
        var filters: [Filter] = []

        if let groupBy = range.view.groupBy {
            guard let field = definition.field(named: groupBy, at: definition.version) else {
                return nil
            }
            guard let parse = field.type.canonicalParser, let value = parse(range.group) else {
                return nil
            }

            filters.append(Filter(field: groupBy, op: .equals, value: value))
        }

        if let dateField = definition.envelopeDate, let window = range.window {
            filters.append(Filter(field: dateField, op: .greaterThanOrEquals, value: .date(window.from)))
            filters.append(Filter(field: dateField, op: .lessThan, value: .date(window.to)))
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

extension GridAggregator.CellRange {
    fileprivate var window: (from: Date, to: Date)? {
        let calendar = EntityCoder.calendar
        let unit: Calendar.Component

        switch view.bucket ?? .hour {
        case .hour:
            unit = .hour
        case .weekday, .day:
            unit = .day
        case .lifetime:
            return nil
        }

        guard let from = calendar.date(byAdding: unit, value: index, to: period) else {
            return nil
        }
        guard let to = calendar.date(byAdding: unit, value: 1, to: from) else {
            return nil
        }

        return (from, to)
    }
}
