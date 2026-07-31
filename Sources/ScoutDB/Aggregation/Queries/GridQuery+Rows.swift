//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension GridQuery {
    func rows() async throws -> [AggregateRow] {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view) else {
            throw SchemaError.unknownField(view)
        }

        let kind = declared.metric?.kind
        let isStats = declared.stats != nil
        let cells = 0..<(isStats ? CKRecord.squareOffset : CKRecord.cellCount)

        let records = try await store.gridRecords(
            entity: entity,
            view: view,
            group: group,
            from: declared.gridStart(from: from),
            to: to,
            counts: cells,
            values: kind == nil ? nil : 0..<CKRecord.cellCount
        )

        let covers = declared.cellFilter(from: from, to: to)

        let rows = records.compactMap { record -> AggregateRow? in
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else {
                return nil
            }

            var count = 0
            var value: Double?
            var squares: Double?

            for index in cells where covers(period, index) {
                count += Int(record.count(at: index))

                if let kind, let cell = record.value(at: index) {
                    value = value.map { kind.combine($0, cell) } ?? cell
                }
                if isStats, let square = record.square(at: index) {
                    squares = (squares ?? 0) + square
                }
            }

            guard count != 0 || value != nil || squares != nil else {
                return nil
            }

            return AggregateRow(
                group: group,
                period: period,
                count: count,
                value: value,
                squares: squares
            )
        }

        return merging(rows, sharding: { "\($0.period.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateRow(
                group: merged.group,
                period: merged.period,
                count: merged.count + shard.count,
                value: combined(merged.value, shard.value, kind),
                squares: combined(merged.squares, shard.squares, nil)
            )
        }
        .sorted()
    }
}
