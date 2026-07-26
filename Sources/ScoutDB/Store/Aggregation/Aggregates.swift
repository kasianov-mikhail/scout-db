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
    /// Rolls a view's grid up to one row per period and group.
    ///
    /// A row is dated at its period's start, and `from`/`to` narrow it at the
    /// view's cell resolution — a period the range opens or closes inside of
    /// comes back as a partial row holding only the cells the range covers. A
    /// histogram's cells hold values rather than times, so its range resolves
    /// no finer than the day its grid is keyed by.
    ///
    public func aggregate(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> [AggregateRow] {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }
        let records = try await gridRecords(entity: entity, view: viewName, from: Self.gridStart(from, of: view), to: to)
        let covers = Self.cellFilter(view, from: from, to: to)
        let kind = view.metric?.kind
        let isStats = view.stats != nil

        let rows = records.compactMap { record -> AggregateRow? in
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { return nil }
            var count = 0
            var value: Double?
            var squares: Double?
            for index in 0..<(isStats ? Aggregate.squareOffset : Aggregate.cellCount) where covers(period, index) {
                count += Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                if let kind, let cell = record[Aggregate.valueCell(index)] as? Double {
                    value = value.map { kind.combine($0, cell) } ?? cell
                }
                if isStats, let square = record[Aggregate.squareCell(index)] as? Double {
                    squares = (squares ?? 0) + square
                }
            }
            guard count != 0 || value != nil || squares != nil else { return nil }
            return AggregateRow(group: group, period: period, count: count, value: value, squares: squares)
        }
        return Dictionary(grouping: rows) { "\($0.period.millisecondsSince1970)|\($0.group)" }.values.map { shards -> AggregateRow in
            shards.dropFirst().reduce(shards[0]) { merged, shard in
                let values = [merged.value, shard.value].compactMap { $0 }
                let squares = [merged.squares, shard.squares].compactMap { $0 }
                return AggregateRow(
                    group: merged.group, period: merged.period, count: merged.count + shard.count,
                    value: values.count > 0 ? (values.count == 2 ? (kind?.combine(values[0], values[1]) ?? values[0] + values[1]) : values[0]) : nil,
                    squares: squares.count > 0 ? squares.reduce(0, +) : nil)
            }
        }.sorted { ($0.period, $0.group) < ($1.period, $1.group) }
    }

    /// Reads a view's grid at cell resolution — one point per non-empty bucket cell,
    /// dated at the cell's position within its period (e.g. the hour of the day).
    ///
    /// `from` and `to` bound the points by that cell date, so a period the range
    /// opens or closes inside of contributes only the cells the range covers.
    ///
    public func series(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> [AggregateSeriesPoint] {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }
        let bucket = view.bucket ?? .hour
        let covers = Self.cellFilter(view, from: from, to: to)
        let isStats = view.stats != nil
        let kind = view.metric?.kind
        var points: [AggregateSeriesPoint] = []

        for record in try await gridRecords(entity: entity, view: viewName, from: Self.gridStart(from, of: view), to: to) {
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { continue }
            for index in 0..<(isStats ? Aggregate.squareOffset : Aggregate.cellCount) where covers(period, index) {
                let count = Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                let value = record[Aggregate.valueCell(index)] as? Double
                guard count != 0 || value != nil else { continue }
                points.append(AggregateSeriesPoint(group: group, date: Self.cellDate(bucket, period: period, index: index), count: count, value: value))
            }
        }
        return Dictionary(grouping: points) { "\($0.date.millisecondsSince1970)|\($0.group)" }.values.map { shards -> AggregateSeriesPoint in
            shards.dropFirst().reduce(shards[0]) { merged, shard in
                let values = [merged.value, shard.value].compactMap { $0 }
                return AggregateSeriesPoint(
                    group: merged.group, date: merged.date, count: merged.count + shard.count,
                    value: values.count > 0 ? (values.count == 2 ? (kind?.combine(values[0], values[1]) ?? values[0] + values[1]) : values[0]) : nil)
            }
        }.sorted { ($0.date, $0.group) < ($1.date, $1.group) }
    }

    private static func cellDate(_ bucket: AggregateView.Bucket, period: Date, index: Int) -> Date {
        switch bucket {
        case .hour:
            return EntityCoder.calendar.date(byAdding: .hour, value: index, to: period) ?? period
        case .weekday, .day:
            return EntityCoder.calendar.date(byAdding: .day, value: index, to: period) ?? period
        case .lifetime:
            return period
        }
    }

    private static func period(of bucket: AggregateView.Bucket) -> Calendar.Component? {
        switch bucket {
        case .hour: .day
        case .weekday: .weekOfYear
        case .day: .month
        case .lifetime: nil
        }
    }

    private static func gridStart(_ from: Date?, of view: AggregateView) -> Date? {
        guard let from else { return nil }
        guard view.histogram == nil else { return EntityCoder.periodStart(of: .day, for: from) }
        guard let period = period(of: view.bucket ?? .hour) else { return from }
        return EntityCoder.periodStart(of: period, for: from)
    }

    private static func cellFilter(_ view: AggregateView, from: Date?, to: Date?) -> (Date, Int) -> Bool {
        guard view.histogram == nil, from != nil || to != nil else { return { _, _ in true } }
        let bucket = view.bucket ?? .hour
        return { period, index in
            let date = cellDate(bucket, period: period, index: index)
            if let from, date < from { return false }
            if let to, date >= to { return false }
            return true
        }
    }

    public func totals(entity: String, view viewName: String, from: Date? = nil, to: Date? = nil, having: (AggregateTotal) -> Bool = { _ in true }) async throws
        -> [AggregateTotal]
    {
        let definition = try await registry.definition(for: entity)
        let kind = definition.view(named: viewName)?.metric?.kind
        let rows = try await aggregate(entity: entity, view: viewName, from: from, to: to)

        return Dictionary(grouping: rows, by: \.group).map { group, rows in
            let count = rows.reduce(0) { $0 + $1.count }
            let values = rows.compactMap(\.value)
            let value: Double? = values.count > 0 ? values.dropFirst().reduce(values[0]) { kind?.combine($0, $1) ?? $0 + $1 } : nil
            let squares = rows.compactMap(\.squares)
            return AggregateTotal(group: group, count: count, value: value, squares: squares.count > 0 ? squares.reduce(0, +) : nil)
        }.filter(having).sorted { $0.group < $1.group }
    }

    /// Interpolates a percentile from a histogram view's counts.
    ///
    /// A histogram's cells hold value buckets rather than times, so `from` and
    /// `to` resolve no finer than the day its grid is keyed by — a bound inside
    /// a day takes that whole day in.
    ///
    public func percentile(_ p: Double, entity: String, view viewName: String, from: Date? = nil, to: Date? = nil) async throws -> Double? {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName), let histogram = view.histogram else {
            throw SchemaError.invalidValue(viewName)
        }

        var counts = [Double](repeating: 0, count: histogram.bounds.count + 1)
        for record in try await gridRecords(entity: entity, view: viewName, from: Self.gridStart(from, of: view), to: to) {
            for index in counts.indices {
                counts[index] += Double(record[Aggregate.countCell(index)] as? Int64 ?? 0)
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
        for record in try await read(entity: entity, filters: filters, fields: [field]) {
            guard let value = record.values[field] else { continue }
            if seen.insert(value.canonical).inserted {
                values.append(value)
            }
        }
        return values
    }

    /// The count a declared view answers without scanning records, or nil when
    /// no view covers the query.
    ///
    /// Covered shapes: no filters or a `groupBy` equality (lifetime view); an
    /// `envelopeDate` range whose bounds align with a view's cell resolution
    /// (hour cells for an hour view, day cells for day and weekday views); a
    /// threshold on a histogram's field that lands exactly on a declared bound.
    ///
    package func viewCount(entity: String, filters: [Filter]) async throws -> Int? {
        let definition = try await registry.definition(for: entity)
        guard definition.views?.isEmpty == false, let query = CountQuery(filters, envelopeDate: definition.envelopeDate) else { return nil }

        if query.numericField != nil {
            guard query.from == nil, query.to == nil, let (view, cells) = Self.histogramPlan(for: query, in: definition) else { return nil }
            let records = try await gridRecords(entity: entity, view: view.name, from: nil, to: nil)
            var total = 0
            for record in records where query.groupKey == nil || record["group_key"] as? String == query.groupKey {
                for index in cells {
                    total += Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                }
            }
            return total
        }

        guard let folded = try await gridFold(query, of: nil, by: nil, entity: entity, in: definition) else { return nil }
        return folded.values.reduce(0) { $0 + $1.count }
    }

    package struct GridFold: Equatable, Sendable {
        package var count = 0
        package var total = 0.0
    }

    package func viewFold(of field: String?, by group: String?, entity: String, filters: [Filter]) async throws -> [String: GridFold]? {
        let definition = try await registry.definition(for: entity)
        guard definition.views?.isEmpty == false, let query = CountQuery(filters, envelopeDate: definition.envelopeDate), query.numericField == nil
        else { return nil }
        return try await gridFold(query, of: field, by: group, entity: entity, in: definition)
    }

    package func alwaysPresent(_ field: String, entity: String) async throws -> Bool {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else { return false }
        return target.alwaysPresent
    }

    private func gridFold(_ query: CountQuery, of field: String?, by group: String?, entity: String, in definition: EntityDefinition) async throws
        -> [String: GridFold]?
    {
        guard group == nil || query.groupField == nil || query.groupField == group else { return nil }
        guard let view = Self.foldPlan(for: query, in: definition, summing: field, grouping: group) else { return nil }
        let covers = Self.cellFilter(view, from: query.from, to: query.to)
        let records = try await gridRecords(entity: entity, view: view.name, from: Self.gridStart(query.from, of: view), to: query.to)

        var folded: [String: GridFold] = [:]
        for record in records where query.groupKey == nil || record["group_key"] as? String == query.groupKey {
            guard let start = record["date"] as? Date, let key = record["group_key"] as? String else { continue }
            var bucketed = folded[group == nil ? "" : key] ?? GridFold()
            for index in 0..<Aggregate.squareOffset where covers(start, index) {
                let count = Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                guard count != 0 else { continue }
                bucketed.count += count
                bucketed.total += record[Aggregate.valueCell(index)] as? Double ?? 0
            }
            guard bucketed.count > 0 else { continue }
            folded[group == nil ? "" : key] = bucketed
        }
        return folded
    }

    private struct CountQuery {
        var groupField: String?
        var groupKey: String?
        var from: Date?
        var to: Date?
        var numericField: String?
        var numericGTE: Double?
        var numericLT: Double?

        init?(_ filters: [Filter], envelopeDate: String?) {
            for filter in filters {
                guard !filter.negated, filter.radius == nil else { return nil }
                switch (filter.op, filter.value) {
                case (.greaterThanOrEquals, .date(let date)) where filter.field == envelopeDate:
                    guard from == nil else { return nil }
                    from = date
                case (.lessThan, .date(let date)) where filter.field == envelopeDate:
                    guard to == nil else { return nil }
                    to = date
                case (.equals, let value):
                    guard groupField == nil else { return nil }
                    groupField = filter.field
                    groupKey = value.canonical
                case (.greaterThanOrEquals, let value):
                    guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericGTE == nil else { return nil }
                    numericField = filter.field
                    numericGTE = scalar
                case (.lessThan, let value):
                    guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericLT == nil else { return nil }
                    numericField = filter.field
                    numericLT = scalar
                default:
                    return nil
                }
            }
        }

        func matchesGrouping(of view: AggregateView) -> Bool {
            groupField == nil || groupField == view.groupBy
        }
    }

    private static func foldPlan(for query: CountQuery, in definition: EntityDefinition, summing field: String?, grouping group: String?)
        -> AggregateView?
    {
        let ranged = query.from != nil || query.to != nil
        for view in definition.views ?? [] where view.histogram == nil && query.matchesGrouping(of: view) {
            guard group == nil || view.groupBy == group else { continue }
            guard field == nil || view.sum == field || view.stats == field else { continue }
            let bucket = view.bucket ?? .hour
            guard ranged else {
                guard bucket == .lifetime else { continue }
                return view
            }
            guard bucket != .lifetime else { continue }
            let unit: Calendar.Component = bucket == .hour ? .hour : .day
            let aligned = [query.from, query.to].compactMap { $0 }.allSatisfy { EntityCoder.periodStart(of: unit, for: $0) == $0 }
            guard aligned else { continue }
            return view
        }
        return nil
    }

    private static func histogramPlan(for query: CountQuery, in definition: EntityDefinition) -> (view: AggregateView, cells: ClosedRange<Int>)? {
        for view in definition.views ?? [] {
            guard let histogram = view.histogram, histogram.field == query.numericField, query.matchesGrouping(of: view) else { continue }
            var first = 0
            var last = histogram.bounds.count
            if let gte = query.numericGTE {
                guard let bound = histogram.bounds.firstIndex(of: gte) else { continue }
                first = bound + 1
            }
            if let below = query.numericLT {
                guard let bound = histogram.bounds.firstIndex(of: below) else { continue }
                last = bound
            }
            guard first <= last else { continue }
            return (view, first...last)
        }
        return nil
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
        return try await database.allRecords(matching: ckQuery(Aggregate.recordType, filters: filters))
    }
}
