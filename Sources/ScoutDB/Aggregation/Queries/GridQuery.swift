//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct GridQuery {
    let store: EntityStore
    let entity: String
    let view: String
    var group: String?
    var from: Date?
    var to: Date?

    init(_ store: EntityStore, entity: String, view: String, group: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.store = store
        self.entity = entity
        self.view = view
        self.group = group
        self.from = from
        self.to = to
    }

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

        return Self.merging(rows, sharding: { "\($0.period.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateRow(
                group: merged.group,
                period: merged.period,
                count: merged.count + shard.count,
                value: Self.combined(merged.value, shard.value, kind),
                squares: Self.combined(merged.squares, shard.squares, nil)
            )
        }
        .sorted()
    }

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

        return Self.merging(points, sharding: { "\($0.date.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateSeriesPoint(
                group: merged.group,
                date: merged.date,
                count: merged.count + shard.count,
                value: Self.combined(merged.value, shard.value, kind)
            )
        }
        .sorted()
    }

    func totals(having: (AggregateTotal) -> Bool = { _ in true }) async throws -> [AggregateTotal] {
        let kind = try await store.registry
            .definition(for: entity)
            .view(named: view)?
            .metric?.kind

        let rows = try await rows()

        return Dictionary(grouping: rows, by: \.group).map { group, rows in
            let count = rows.reduce(0) {
                $0 + $1.count
            }
            let value = rows.reduce(Double?.none) {
                Self.combined($0, $1.value, kind)
            }
            let squares = rows.reduce(Double?.none) {
                Self.combined($0, $1.squares, nil)
            }

            return AggregateTotal(
                group: group,
                count: count,
                value: value,
                squares: squares
            )
        }
        .filter(having).sorted()
    }

    func percentile(_ p: Double) async throws -> Double? {
        let definition = try await store.registry.definition(for: entity)

        guard let declared = definition.view(named: view), let histogram = declared.histogram else {
            throw SchemaError.invalidValue(view)
        }

        var counts = [Double](repeating: 0, count: histogram.bounds.count + 1)

        let records = try await store.gridRecords(
            entity: entity,
            view: view,
            group: group,
            from: declared.gridStart(from: from),
            to: to,
            counts: counts.indices
        )

        for record in records {
            for index in counts.indices {
                counts[index] += Double(record.count(at: index))
            }
        }

        let total = counts.reduce(0, +)

        guard total > 0 else {
            return nil
        }

        let target = p * total
        var cumulative = 0.0

        for (index, count) in counts.enumerated() where count > 0 {
            if cumulative + count >= target {
                if index == 0 {
                    return histogram.bounds.first
                }
                if index == counts.count - 1 {
                    return histogram.bounds.last
                }

                let lower = histogram.bounds[index - 1]
                let upper = histogram.bounds[index]

                return lower + (target - cumulative) / count * (upper - lower)
            }
            cumulative += count
        }

        return histogram.bounds.last
    }

    private static func merging<Row>(_ rows: [Row], sharding key: (Row) -> String, _ combine: (Row, Row) -> Row) -> [Row] {
        Dictionary(grouping: rows, by: key).values.map { shards in
            shards.dropFirst().reduce(shards[0], combine)
        }
    }

    private static func combined(_ lhs: Double?, _ rhs: Double?, _ kind: Metric?) -> Double? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return kind?.combine(lhs, rhs) ?? lhs + rhs
    }
}
