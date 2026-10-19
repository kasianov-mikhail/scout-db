//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// The first hour from which the aggregate counts every record, or nil
    /// when it has counted since the entity was created.
    ///
    /// An aggregate that ``SchemaBuilder/update()`` adds to an entity that
    /// already holds records starts empty: its cells count only what is
    /// written after it. The hours before this date are missing from
    /// ``series(_:metric:group:in:)`` and ``totals(_:metric:group:)``, so read
    /// them from the records instead. `metric` and `group` pick the aggregate
    /// as they do for a series, and `.average` answers the later date of the
    /// two aggregates it divides.
    ///
    /// A client keeps the schema it loaded until it restarts, so writes from
    /// a client that loaded it before the aggregate joined are not counted.
    ///
    /// ```swift
    /// let start = try await store.query("purchase").coverage("amount", metric: .sum, group: "product_id")
    /// // nil: the series covers every hour
    /// // a date: count the hours before it from the records
    /// ```
    ///
    public func coverage(_ field: String? = nil, metric: Metric, group: String? = nil) async throws -> Date? {
        try await cells.coverage(field: field, metric: metric, group: group)
    }
}
