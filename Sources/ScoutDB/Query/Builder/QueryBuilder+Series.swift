//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// One point per group and hour the range covers, read off the same
    /// vectors ``totals(_:metric:group:)`` folds whole.
    ///
    /// A cell is an hour, so this is the finest a vector goes — roll the points
    /// up into days or weeks on the client, which costs nothing once they are
    /// in hand. The read costs one record per group and week the range touches,
    /// whatever the entity grows to, and the weeks come off the aggregate's
    /// index rather than a scan.
    ///
    /// An hour nothing wrote has no cell and no point: the series is sparse,
    /// and a gap is a gap rather than a zero. `metric` and `group` pick the
    /// declared aggregate as they do for a total, `.average` divides the `sum`
    /// aggregate by the count one hour by hour, and the only clause a vector
    /// read honors is an equality filter on the grouping field.
    ///
    /// ```swift
    /// let revenue = try await store.query("purchase")
    ///     .series("amount", metric: .sum, group: "product_id", in: week)
    /// // [SeriesPoint(group: "sku-42", date: ..., value: 481.62), ...]
    /// ```
    ///
    public func series(
        _ field: String? = nil, metric: Metric, group: String? = nil, in range: Range<Date>
    ) async throws -> [SeriesPoint] {
        try await series(field, metric: metric, groups: group.map { [$0] } ?? [], in: range)
    }

    /// One point per combination of the grouping fields and hour, read off an
    /// aggregate declared over the same list of fields, in the same order.
    ///
    /// A point's ``SeriesPoint/group`` joins the values of the fields, and
    /// ``SeriesPoint/groupValues`` splits them back. A record missing one of
    /// the fields counts under an empty value for it. A vector read over
    /// several fields honors no filter.
    ///
    /// ```swift
    /// let sessions = try await store.query("session")
    ///     .series(metric: .sum, groups: ["channel", "app_version"], in: week)
    /// // sessions[0].groupValues == ["TestFlight", "1.2.0"]
    /// ```
    ///
    public func series(_ field: String? = nil, metric: Metric, groups: [String], in range: Range<Date>) async throws
        -> [SeriesPoint]
    {
        let cells = try await cells

        guard metric == .average, let field else {
            return try await cells.points(field: field, metric: metric, groups: groups, in: range)
        }
        return try await cells.averages(field: field, groups: groups, in: range)
    }
}

/// What one group of an aggregate holds for one hour.
public struct SeriesPoint: Hashable, Sendable {
    /// The value of the aggregate's grouping field, or the empty string when it groups by nothing.
    public let group: String

    /// The hour the cell covers, at its start.
    public let date: Date

    /// The metric folded over that hour, or the count of records when the aggregate folds none.
    public let value: Double

    public init(group: String, date: Date, value: Double) {
        self.group = group
        self.date = date
        self.value = value
    }

    /// The values of the grouping fields, in the order a read over several
    /// fields named them.
    ///
    /// Read it only off a series over several fields: a single field's value
    /// is the whole ``group`` as it is.
    ///
    public var groupValues: [String] {
        group.groupValues
    }
}

extension SeriesPoint: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.date, lhs.group) < (rhs.date, rhs.group)
    }
}
