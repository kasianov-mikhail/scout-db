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
    /// no finer than the day its grid is keyed by. A `group` narrows the read
    /// to that group's rows server-side — a single group of a high-cardinality
    /// view never pages through the other groups' rows.
    ///
    public func aggregate(entity: String, view viewName: String, group: String? = nil, from: Date? = nil, to: Date? = nil) async throws
        -> [AggregateRow]
    {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }
        let kind = view.metric?.kind
        let isStats = view.stats != nil
        let cells = 0..<(isStats ? Aggregate.squareOffset : Aggregate.cellCount)
        let records = try await gridRecords(
            entity: entity, view: viewName, group: group, from: Self.gridStart(from, of: view), to: to, counts: cells,
            values: kind == nil ? nil : 0..<Aggregate.cellCount)
        let covers = Self.cellFilter(view, from: from, to: to)

        let rows = records.compactMap { record -> AggregateRow? in
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { return nil }
            var count = 0
            var value: Double?
            var squares: Double?
            for index in cells where covers(period, index) {
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
        return Self.merging(rows, sharding: { "\($0.period.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateRow(
                group: merged.group, period: merged.period, count: merged.count + shard.count,
                value: Self.combined(merged.value, shard.value, kind), squares: Self.combined(merged.squares, shard.squares, nil))
        }.sorted { ($0.period, $0.group) < ($1.period, $1.group) }
    }

    /// Reads a view's grid at cell resolution — one point per non-empty bucket cell,
    /// dated at the cell's position within its period (e.g. the hour of the day).
    ///
    /// `from` and `to` bound the points by that cell date, so a period the range
    /// opens or closes inside of contributes only the cells the range covers.
    /// A `group` narrows the read to that group's rows server-side.
    ///
    public func series(entity: String, view viewName: String, group: String? = nil, from: Date? = nil, to: Date? = nil) async throws
        -> [AggregateSeriesPoint]
    {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName) else {
            throw SchemaError.unknownField(viewName)
        }
        let bucket = view.bucket ?? .hour
        let covers = Self.cellFilter(view, from: from, to: to)
        let isStats = view.stats != nil
        let kind = view.metric?.kind
        var points: [AggregateSeriesPoint] = []
        let cells = 0..<(isStats ? Aggregate.squareOffset : Aggregate.cellCount)

        let records = try await gridRecords(
            entity: entity, view: viewName, group: group, from: Self.gridStart(from, of: view), to: to, counts: cells,
            values: kind == nil ? nil : cells)

        for record in records {
            guard let period = record["date"] as? Date, let group = record["group_key"] as? String else { continue }
            for index in cells where covers(period, index) {
                let count = Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                let value = record[Aggregate.valueCell(index)] as? Double
                guard count != 0 || value != nil else { continue }
                points.append(AggregateSeriesPoint(group: group, date: Self.cellDate(bucket, period: period, index: index), count: count, value: value))
            }
        }
        return Self.merging(points, sharding: { "\($0.date.millisecondsSince1970)|\($0.group)" }) { merged, shard in
            AggregateSeriesPoint(
                group: merged.group, date: merged.date, count: merged.count + shard.count, value: Self.combined(merged.value, shard.value, kind))
        }.sorted { ($0.date, $0.group) < ($1.date, $1.group) }
    }

    private static func merging<Row>(_ rows: [Row], sharding key: (Row) -> String, _ combine: (Row, Row) -> Row) -> [Row] {
        Dictionary(grouping: rows, by: key).values.map { shards in shards.dropFirst().reduce(shards[0], combine) }
    }

    private static func combined(_ lhs: Double?, _ rhs: Double?, _ kind: AggregateView.Metric?) -> Double? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return kind?.combine(lhs, rhs) ?? lhs + rhs
    }

    private static func cellDate(_ bucket: AggregateView.Bucket, period: Date, index: Int) -> Date {
        switch bucket {
        case .hour:
            EntityCoder.calendar.date(byAdding: .hour, value: index, to: period) ?? period
        case .weekday, .day:
            EntityCoder.calendar.date(byAdding: .day, value: index, to: period) ?? period
        case .lifetime:
            period
        }
    }

    private static func period(of bucket: AggregateView.Bucket) -> Calendar.Component? {
        switch bucket {
        case .hour:
            .day
        case .weekday:
            .weekOfYear
        case .day:
            .month
        case .lifetime:
            nil
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

    public func totals(
        entity: String, view viewName: String, group: String? = nil, from: Date? = nil, to: Date? = nil,
        having: (AggregateTotal) -> Bool = { _ in true }
    ) async throws
        -> [AggregateTotal]
    {
        let definition = try await registry.definition(for: entity)
        let kind = definition.view(named: viewName)?.metric?.kind
        let rows = try await aggregate(entity: entity, view: viewName, group: group, from: from, to: to)

        return Dictionary(grouping: rows, by: \.group).map { group, rows in
            let count = rows.reduce(0) { $0 + $1.count }
            let value = rows.reduce(Double?.none) { Self.combined($0, $1.value, kind) }
            let squares = rows.reduce(Double?.none) { Self.combined($0, $1.squares, nil) }
            return AggregateTotal(group: group, count: count, value: value, squares: squares)
        }.filter(having).sorted { $0.group < $1.group }
    }

    /// Interpolates a percentile from a histogram view's counts.
    ///
    /// A histogram's cells hold value buckets rather than times, so `from` and
    /// `to` resolve no finer than the day its grid is keyed by — a bound inside
    /// a day takes that whole day in. A `group` narrows the read to that
    /// group's rows server-side.
    ///
    public func percentile(_ p: Double, entity: String, view viewName: String, group: String? = nil, from: Date? = nil, to: Date? = nil) async throws
        -> Double?
    {
        let definition = try await registry.definition(for: entity)
        guard let view = definition.view(named: viewName), let histogram = view.histogram else {
            throw SchemaError.invalidValue(viewName)
        }

        var counts = [Double](repeating: 0, count: histogram.bounds.count + 1)
        for record in try await gridRecords(
            entity: entity, view: viewName, group: group, from: Self.gridStart(from, of: view), to: to, counts: counts.indices)
        {
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

    /// The distinct values of a field across the matching records.
    ///
    /// A view grouping by an always-present, unencrypted field answers the
    /// query shapes ``viewCount(entity:filters:)`` covers from its grid — one
    /// row per live value, without reading records. Every other shape scans,
    /// fetching only the field's slot.
    ///
    public func distinct(entity: String, field: String, filters: [Filter] = []) async throws -> [RecordValue] {
        let definition = try await registry.definition(for: entity)
        if let target = definition.field(named: field, at: definition.version), target.alwaysPresent, target.encrypted != true,
            let parse = Self.canonicalParser(of: target.type),
            let folded = try await viewFold(of: nil, by: field, entity: entity, filters: filters)
        {
            return folded.keys.sorted().compactMap(parse)
        }
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

    static func canonicalParser(of type: FieldType) -> ((String) -> RecordValue?)? {
        switch type {
        case .string, .text:
            return { .string($0) }
        case .int:
            return { $0.hasPrefix("i") ? Int64($0.dropFirst()).map(RecordValue.int) : nil }
        case .double:
            return { $0.hasPrefix("d") ? Double($0.dropFirst()).map(RecordValue.double) : nil }
        case .timestamp:
            return { canonical in
                guard canonical.hasPrefix("t"), let milliseconds = Int64(canonical.dropFirst()) else { return nil }
                return .date(Date(millisecondsSince1970: milliseconds))
            }
        case .reference:
            return { $0.hasPrefix("r") ? .reference(String($0.dropFirst())) : nil }
        default:
            return nil
        }
    }

    package func viewCount(entity: String, filters: [Filter]) async throws -> Int? {
        try await viewCount(entity: entity, any: [filters])
    }

    package func viewCount(entity: String, any branches: [[Filter]]) async throws -> Int? {
        let definition = try await registry.definition(for: entity)
        guard definition.views?.isEmpty == false, let parsed = CountQuery(any: branches, envelopeDate: definition.envelopeDate) else { return nil }
        let query = Self.keyed(parsed, in: definition) ?? parsed

        if query.numericField != nil {
            guard query.from == nil, query.to == nil, let (view, cells) = Self.histogramPlan(for: query, in: definition) else { return nil }
            let records = try await gridRecords(entity: entity, view: view.name, group: query.serverGroup, counts: cells)
            var total = 0
            for record in records {
                guard let key = record["group_key"] as? String, query.covers(key) else { continue }
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
        package var value: Double?
    }

    package func viewFold(of field: String?, folding kind: AggregateView.Metric = .sum, by group: String?, entity: String, filters: [Filter])
        async throws -> [String: GridFold]?
    {
        try await viewFold(of: field, folding: kind, by: group, entity: entity, any: [filters])
    }

    package func viewFold(of field: String?, folding kind: AggregateView.Metric = .sum, by group: String?, entity: String, any branches: [[Filter]])
        async throws -> [String: GridFold]?
    {
        let definition = try await registry.definition(for: entity)
        guard definition.views?.isEmpty == false, let parsed = CountQuery(any: branches, envelopeDate: definition.envelopeDate) else { return nil }
        let query = Self.keyed(parsed, in: definition) ?? parsed
        guard query.numericField == nil else { return nil }
        return try await gridFold(query, of: field, folding: kind, by: group, entity: entity, in: definition)
    }

    package func alwaysPresent(_ field: String, entity: String) async throws -> Bool {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else { return false }
        return target.alwaysPresent
    }

    private func gridFold(
        _ query: CountQuery, of field: String?, folding kind: AggregateView.Metric = .sum, by group: String?, entity: String,
        in definition: EntityDefinition
    ) async throws -> [String: GridFold]? {
        guard group == nil || query.groupField == nil || query.groupField == group else { return nil }
        guard let view = Self.foldPlan(for: query, in: definition, folding: field.map { (kind, $0) }, grouping: group) else { return nil }
        let covers = Self.cellFilter(view, from: query.from, to: query.to)
        let cells = 0..<Aggregate.squareOffset
        let records = try await gridRecords(
            entity: entity, view: view.name, group: query.serverGroup, from: Self.gridStart(query.from, of: view), to: query.to, counts: cells,
            values: field == nil ? nil : cells)

        var folded: [String: GridFold] = [:]
        for record in records {
            guard let start = record["date"] as? Date, let key = record["group_key"] as? String, query.covers(key) else { continue }
            var bucketed = folded[group == nil ? "" : key] ?? GridFold()
            for index in cells where covers(start, index) {
                let count = Int(record[Aggregate.countCell(index)] as? Int64 ?? 0)
                guard count != 0 else { continue }
                bucketed.count += count
                if let cell = record[Aggregate.valueCell(index)] as? Double {
                    bucketed.value = bucketed.value.map { kind.combine($0, cell) } ?? cell
                }
            }
            guard bucketed.count > 0 else { continue }
            folded[group == nil ? "" : key] = bucketed
        }
        return folded
    }

    private struct CountQuery {
        var groupField: String?
        var groupKeys: Set<String>?
        var from: Date?
        var to: Date?
        var numericField: String?
        var numericGTE: Double?
        var numericLT: Double?

        var serverGroup: String? {
            groupKeys?.count == 1 ? groupKeys?.first : nil
        }

        func covers(_ key: String) -> Bool {
            groupKeys?.contains(key) ?? true
        }

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
                    groupKeys = [value.canonical]
                case (.in, let value):
                    guard groupField == nil, let keys = Self.elementCanonicals(of: value) else { return nil }
                    groupField = filter.field
                    groupKeys = keys
                case (.greaterThanOrEquals, let value):
                    guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericGTE == nil else { return nil }
                    numericField = filter.field
                    numericGTE = scalar
                case (.lessThan, let value):
                    guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericLT == nil else { return nil }
                    numericField = filter.field
                    numericLT = scalar
                case (.greaterThan, .int(let value)):
                    guard value < Int64.max, numericField == nil || numericField == filter.field, numericGTE == nil else { return nil }
                    numericField = filter.field
                    numericGTE = Double(value + 1)
                case (.lessThanOrEquals, .int(let value)):
                    guard value < Int64.max, numericField == nil || numericField == filter.field, numericLT == nil else { return nil }
                    numericField = filter.field
                    numericLT = Double(value + 1)
                default:
                    return nil
                }
            }
        }

        init?(any branches: [[Filter]], envelopeDate: String?) {
            guard let first = branches.first, var merged = CountQuery(first, envelopeDate: envelopeDate) else { return nil }
            for branch in branches.dropFirst() {
                guard let query = CountQuery(branch, envelopeDate: envelopeDate),
                    query.groupField == merged.groupField, query.from == merged.from, query.to == merged.to,
                    query.numericField == merged.numericField, query.numericGTE == merged.numericGTE, query.numericLT == merged.numericLT,
                    let keys = merged.groupKeys, let more = query.groupKeys
                else { return nil }
                merged.groupKeys = keys.union(more)
            }
            self = merged
        }

        func matchesGrouping(of view: AggregateView) -> Bool {
            groupField == nil || groupField == view.groupBy
        }

        private static func elementCanonicals(of value: RecordValue) -> Set<String>? {
            value.members.map { Set($0.map(\.canonical)) }
        }
    }

    private static func foldPlan(
        for query: CountQuery, in definition: EntityDefinition, folding metric: (kind: AggregateView.Metric, field: String)?, grouping group: String?
    ) -> AggregateView? {
        let ranged = query.from != nil || query.to != nil
        for view in definition.views ?? [] where view.histogram == nil && query.matchesGrouping(of: view) {
            guard group == nil || view.groupBy == group else { continue }
            if let metric, !view.answers(metric.kind, of: metric.field) { continue }
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

    private static let namedDomain = 1_024.0

    private static func keyed(_ query: CountQuery, in definition: EntityDefinition) -> CountQuery? {
        guard query.groupField == nil, let name = query.numericField,
            let field = definition.field(named: name, at: definition.version), field.type == .int, field.alwaysPresent, field.encrypted != true,
            case .slot = field.storage, let minimum = field.minimum, let maximum = field.maximum,
            (definition.views ?? []).contains(where: { $0.histogram == nil && $0.groupBy == name })
        else { return nil }

        let floor = Swift.max(minimum.rounded(.up), query.numericGTE?.rounded(.up) ?? -.greatestFiniteMagnitude)
        let ceiling = Swift.min(maximum.rounded(.down), query.numericLT.map { $0.rounded(.up) - 1 } ?? .greatestFiniteMagnitude)
        guard ceiling - floor < namedDomain, let first = Int64(exactly: floor), let last = Int64(exactly: ceiling) else { return nil }

        var keyed = query
        keyed.groupField = name
        keyed.groupKeys = Set((first <= last ? Array(first...last) : []).map { RecordValue.int($0).canonical })
        keyed.numericField = nil
        keyed.numericGTE = nil
        keyed.numericLT = nil
        return keyed
    }

    private static func histogramPlan(for query: CountQuery, in definition: EntityDefinition) -> (view: AggregateView, cells: Range<Int>)? {
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
            return (view, first..<last + 1)
        }
        return nil
    }

    private func gridRecords(
        entity: String, view: String, group: String? = nil, from: Date? = nil, to: Date? = nil, counts: Range<Int>, values: Range<Int>? = nil
    ) async throws -> [CKRecord] {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(view)),
        ]
        if let group {
            filters.append(ServerFilter(field: "group_key", op: .equals, value: .string(group)))
        }
        if let from {
            filters.append(ServerFilter(field: "date", op: .greaterThanOrEquals, value: .date(from)))
        }
        if let to {
            filters.append(ServerFilter(field: "date", op: .lessThan, value: .date(to)))
        }
        let keys = ["date", "group_key"] + counts.map(Aggregate.countCell) + (values.map(Aggregate.valueKeys) ?? [])
        return try await database.allRecords(matching: ckQuery(Aggregate.recordType, filters: filters), desiredKeys: keys)
    }
}
