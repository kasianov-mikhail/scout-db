//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// A metric total paired with its sum of squares, from which the mean and spread
/// derive.
///
/// Grid rows and their per-group totals both expose it.
public protocol AggregateStatistics {
    var count: Int { get }
    var value: Double? { get }
    var squares: Double? { get }
}

extension AggregateStatistics {
    public var average: Double? {
        guard let value, count > 0 else { return nil }
        return value / Double(count)
    }

    public var variance: Double? {
        guard let value, let squares, count > 0 else { return nil }
        let mean = value / Double(count)
        return Swift.max(0, squares / Double(count) - mean * mean)
    }

    public var standardDeviation: Double? {
        variance.map(sqrt)
    }
}

public struct AggregateRow: AggregateStatistics, Equatable, Sendable {
    public let group: String
    public let period: Date
    public let count: Int
    public let value: Double?
    public var squares: Double?
}

public struct AggregateSeriesPoint: Equatable, Sendable {
    public let group: String
    public let date: Date
    public let count: Int
    public let value: Double?
}

public struct AggregateTotal: AggregateStatistics, Equatable, Sendable {
    public let group: String
    public let count: Int
    public let value: Double?
    public var squares: Double?
}

extension EntityStore {
    public func aggregate(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> [AggregateRow] {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.views?.first(where: { $0.name == viewName }) else {
            throw SchemaError.unknownField(viewName)
        }
        let records = try await gridRecords(entity: entity, view: viewName, from: from, to: to)
        let kind = view.metric?.kind
        let isStats = view.stats != nil

        return records.compactMap { record -> AggregateRow? in
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { return nil }
            var count = 0
            var value: Double?
            var squares: Double?
            for index in 0..<64 {
                count += Int(record[GridItem.countCell(index)] as? Int64 ?? 0)
                guard let kind, let cell = record[GridItem.valueCell(index)] as? Double else { continue }
                if isStats, index >= 32 {
                    squares = (squares ?? 0) + cell
                } else {
                    value = value.map { kind.combine($0, cell) } ?? cell
                }
            }
            return AggregateRow(group: group, period: period, count: count, value: value, squares: squares)
        }.sorted { ($0.period, $0.group) < ($1.period, $1.group) }
    }

    /// Reads a view's grid at cell resolution — one point per non-empty bucket cell,
    /// dated at the cell's position within its period (e.g. the hour of the day).
    ///
    public func series(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> [AggregateSeriesPoint] {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.views?.first(where: { $0.name == viewName }) else {
            throw SchemaError.unknownField(viewName)
        }
        let bucket = view.bucket ?? .hour
        let isStats = view.stats != nil
        var points: [AggregateSeriesPoint] = []

        for record in try await gridRecords(entity: entity, view: viewName, from: from, to: to) {
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { continue }
            for index in 0..<(isStats ? 32 : 64) {
                let count = Int(record[GridItem.countCell(index)] as? Int64 ?? 0)
                let value = record[GridItem.valueCell(index)] as? Double
                guard count != 0 || value != nil else { continue }
                points.append(AggregateSeriesPoint(group: group, date: Self.cellDate(bucket, period: period, index: index), count: count, value: value))
            }
        }
        return points.sorted { ($0.date, $0.group) < ($1.date, $1.group) }
    }

    private static func cellDate(_ bucket: AggregateView.Bucket, period: Date, index: Int) -> Date {
        switch bucket {
        case .hour:
            return EntityCoder.calendar.date(byAdding: .hour, value: index, to: period) ?? period
        case .weekday, .day:
            return EntityCoder.calendar.date(byAdding: .day, value: index, to: period) ?? period
        }
    }

    public func totals(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil, having: (AggregateTotal) -> Bool = { _ in true }) async throws
        -> [AggregateTotal]
    {
        let definition = try await registry.definition(for: entity)
        let kind = definition.views?.first { $0.name == viewName }?.metric?.kind
        let rows = try await aggregate(entity: entity, view: viewName, from: from, to: to)

        return Dictionary(grouping: rows, by: \.group).map { group, rows in
            let count = rows.reduce(0) { $0 + $1.count }
            let values = rows.compactMap(\.value)
            let value: Double? = values.count > 0 ? values.dropFirst().reduce(values[0]) { kind?.combine($0, $1) ?? $0 + $1 } : nil
            let squares = rows.compactMap(\.squares)
            return AggregateTotal(group: group, count: count, value: value, squares: squares.count > 0 ? squares.reduce(0, +) : nil)
        }.filter(having).sorted { $0.group < $1.group }
    }

    public func percentile(_ p: Double, entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> Double? {
        let definition = try await registry.definition(for: entity)
        guard let histogram = definition.views?.first(where: { $0.name == viewName })?.histogram else {
            throw SchemaError.invalidValue(viewName)
        }

        var counts = [Double](repeating: 0, count: histogram.bounds.count + 1)
        for record in try await gridRecords(entity: entity, view: viewName, from: from, to: to) {
            for index in counts.indices {
                counts[index] += Double(record[GridItem.countCell(index)] as? Int64 ?? 0)
            }
        }

        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let target = p * total

        var cumulative = 0.0
        for (index, count) in counts.enumerated() where count > 0 {
            if cumulative + count >= target {
                if index == 0 { return histogram.bounds.first }
                if index == counts.count - 1 { return histogram.bounds.last }
                let lower = histogram.bounds[index - 1]
                let upper = histogram.bounds[index]
                return lower + (target - cumulative) / count * (upper - lower)
            }
            cumulative += count
        }
        return histogram.bounds.last
    }

    public func distinct(entity: String, field: String, filters: [Filter] = []) async throws -> [RecordValue] {
        var seen: Set<String> = []
        var values: [RecordValue] = []
        for record in try await read(entity: entity, filters: filters) {
            guard let value = record.values[field] else { continue }
            if seen.insert(value.canonical).inserted {
                values.append(value)
            }
        }
        return values
    }

    private func gridRecords(entity: String, view: String, from: Date?, to: Date?) async throws -> [CKRecord] {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(view)),
        ]
        if let from {
            filters.append(ServerFilter(field: "date", op: .greaterThanOrEquals, value: .date(from)))
        }
        if let to {
            filters.append(ServerFilter(field: "date", op: .lessThan, value: .date(to)))
        }
        return try await database.allRecords(matching: ckQuery(GridItem.recordType, filters: filters))
    }
}
