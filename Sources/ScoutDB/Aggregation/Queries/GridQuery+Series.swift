//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension GridQuery {
    func series() async throws -> [AggregateSeriesPoint] {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view) else {
            throw SchemaError.unknownField(view)
        }

        let bucket = declared.bucket ?? .hour
        let covers = declared.cellFilter(from: from, to: to)
        let isStats = declared.stats != nil
        let kind = declared.metric?.kind
        var points: [AggregateSeriesPoint] = []
        let cells = 0..<(isStats ? CKRecord.squareOffset : CKRecord.cellCount)

        let records = try await store.gridRecords(
            entity: entity,
            view: view,
            group: group,
            from: declared.gridStart(from: from),
            to: to,
            counts: cells,
            values: kind == nil ? nil : cells
        )

        for record in records {
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else {
                continue
            }

            for index in cells where covers(period, index) {
                let count = Int(record.count(at: index))
                let value = record.value(at: index)

                guard count != 0 || value != nil else {
                    continue
                }

                points.append(
                    AggregateSeriesPoint(
                        group: group,
                        date: bucket.cellDate(period: period, index: index),
                        count: count,
                        value: value
                    )
                )
            }
        }

        return merging(points, sharding: { "\($0.date.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateSeriesPoint(
                group: merged.group,
                date: merged.date,
                count: merged.count + shard.count,
                value: combined(merged.value, shard.value, kind)
            )
        }
        .sorted()
    }
}
