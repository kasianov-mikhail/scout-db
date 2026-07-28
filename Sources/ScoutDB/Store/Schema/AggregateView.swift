//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A materialized aggregate over one entity, updated by every write instead of
/// computed by a read.
///
/// A view lays a grid over the entity — one cell per group and period — and
/// each cell is a record holding the count and, at most, one metric. Reads
/// fetch those cells, never the records behind them.
///
public struct AggregateView: Codable, Equatable, Sendable {
    /// Names the view within its entity; reads ask for it by this name.
    public let name: String

    /// The field whose value splits the grid into groups; without it the whole
    /// entity is one group.
    public var groupBy: String?

    /// The period one cell covers, `hour` when left unsaid.
    public var bucket: Bucket?

    /// Keeps a running total of the named field, which `average` derives from
    /// at read time.
    public var sum: String?

    /// Keeps the smallest value of the named field the cell has seen, or still
    /// holds when `exact` is on.
    public var min: String?

    /// Keeps the largest value of the named field the cell has seen, or still
    /// holds when `exact` is on.
    public var max: String?

    /// Keeps Σx and Σx² of the named field, which `variance` and
    /// `standardDeviation` derive from at read time.
    public var stats: String?

    /// Counts the named field's values into fixed buckets, which percentiles
    /// are read off.
    public var histogram: Histogram?

    /// Spreads each grid slot over this many shard records.
    ///
    /// Concurrent writers of one hot slot stop contending on a single CAS
    /// record; readers sum the shards. Worth declaring only for slots many
    /// devices hit at once — every reader still fetches all shard records.
    public var shards: Int?

    /// Keeps a `min`/`max` exact when the record holding the extremum leaves.
    ///
    /// An extremum cannot be un-applied from a counter, so by default a
    /// removal decrements the count and leaves the value standing — it is the
    /// most extreme value the cell ever saw, not the most extreme it still
    /// holds. Declaring this recomputes the affected cell from the records
    /// behind it instead, at the cost of one query per removal that actually
    /// takes the extremum out. The recompute reads one cell's worth of
    /// records — an hour, a day or a week of one group — so a `lifetime`
    /// bucket rereads the whole group and is rarely worth it.
    ///
    /// Only for a `min` or `max` view, and not alongside `shards`: a shard
    /// holds an arbitrary slice of the records, which no query can name.
    ///
    public var exact: Bool?

    public init(
        name: String, groupBy: String? = nil, bucket: Bucket? = nil, sum: String? = nil, min: String? = nil, max: String? = nil, stats: String? = nil,
        histogram: Histogram? = nil, shards: Int? = nil, exact: Bool? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.bucket = bucket
        self.sum = sum
        self.min = min
        self.max = max
        self.stats = stats
        self.histogram = histogram
        self.shards = shards
        self.exact = exact
    }

    /// The bucketing of a numeric field into counters, one per range.
    public struct Histogram: Codable, Equatable, Sendable {
        /// The numeric field whose values are bucketed.
        public let field: String

        /// The buckets' exclusive upper bounds, ascending; whatever reaches
        /// the last one lands in an overflow bucket past it.
        public let bounds: [Double]

        public init(field: String, bounds: [Double]) {
            self.field = field
            self.bounds = bounds
        }
    }

    /// The period one grid cell of a view covers.
    public enum Bucket: String, Codable, Sendable {
        /// Cells an hour wide, or a day wide — `weekday` and `day` both read
        /// per day and differ only in how many cells share a grid record, a
        /// week's worth or a month's.
        case hour, weekday, day

        /// One running total per group, with no time grid — the categorical
        /// counter. The only bucket that works without an envelope date.
        case lifetime
    }

    /// How a cell folds the values written into it.
    public enum Metric: Equatable, Sendable {
        case sum, min, max

        func combine(_ lhs: Double, _ rhs: Double) -> Double {
            switch self {
            case .sum:
                lhs + rhs
            case .min:
                Swift.min(lhs, rhs)
            case .max:
                Swift.max(lhs, rhs)
            }
        }
    }

    var metric: (kind: Metric, field: String)? {
        if let sum { return (.sum, sum) }
        if let min { return (.min, min) }
        if let max { return (.max, max) }
        if let stats { return (.sum, stats) }
        return nil
    }

    func answers(_ kind: Metric, of field: String) -> Bool {
        switch kind {
        case .sum:
            sum == field || stats == field
        case .min:
            min == field && exact == true
        case .max:
            max == field && exact == true
        }
    }
}
