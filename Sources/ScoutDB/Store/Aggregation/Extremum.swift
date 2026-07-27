//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// The extremum one cell of an `exact` view still holds, read back from the
    /// records behind it.
    ///
    /// Runs when a removal took the cell's standing extremum out, which no
    /// counter can un-apply. The read is narrowed to the cell — its group and
    /// the period its index addresses — so it costs that hour, day or week of
    /// one group; a `lifetime` bucket has no period to narrow by and rereads
    /// the group whole. Nil where the cell has no records left, which clears
    /// the value the way an empty cell should read.
    ///
    func extremum(in range: GridAggregator.CellRange, using definition: EntityDefinition) async throws -> Double? {
        guard let metric = range.view.metric, metric.kind != .sum else { return nil }
        var filters: [Filter] = []

        if let groupBy = range.view.groupBy {
            guard let field = definition.field(named: groupBy, at: definition.version),
                let parse = Self.canonicalParser(of: field.type),
                let value = parse(range.group)
            else { return nil }
            filters.append(Filter(field: groupBy, op: .equals, value: value))
        }
        if let dateField = definition.envelopeDate, let window = Self.window(of: range) {
            filters.append(Filter(field: dateField, op: .greaterThanOrEquals, value: .date(window.from)))
            filters.append(Filter(field: dateField, op: .lessThan, value: .date(window.to)))
        }

        let scalars = try await read(entity: definition.entity, filters: filters, fields: [metric.field])
            .compactMap { $0.values[metric.field]?.scalar }
        return metric.kind == .min ? scalars.min() : scalars.max()
    }

    /// The half-open period a cell index addresses, or nil for a `lifetime`
    /// bucket, whose single cell spans every record of its group.
    private static func window(of range: GridAggregator.CellRange) -> (from: Date, to: Date)? {
        let calendar = EntityCoder.calendar
        let unit: Calendar.Component
        switch range.view.bucket ?? .hour {
        case .hour:
            unit = .hour
        case .weekday, .day:
            unit = .day
        case .lifetime:
            return nil
        }
        guard let from = calendar.date(byAdding: unit, value: range.index, to: range.period),
            let to = calendar.date(byAdding: unit, value: 1, to: from)
        else { return nil }
        return (from, to)
    }
}
