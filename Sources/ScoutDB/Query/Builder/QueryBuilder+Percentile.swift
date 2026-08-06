//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// The value a `rank` share of the field's records falls under, read off a
    /// declared histogram.
    ///
    /// The read costs one bucket record per bound and week, whatever the entity
    /// grows to — the records themselves are never touched. `rank` runs 0 through 1,
    /// so a 95th percentile is `0.95`, and the answer is interpolated inside
    /// the bucket it lands in: it is as fine as ``SchemaBuilder/histogram(of:bounds:at:)``
    /// made its bounds, and never finer. `nil` when nothing carries the field.
    ///
    /// A value under the first bound or over the last answers with that bound,
    /// since an open bucket has no edge to interpolate against.
    ///
    /// Unlike the other folds this one has no scan to fall back on: an entity
    /// keeping no histogram of the field throws rather than reading every
    /// record. Filters throw too, because a histogram spends its grouping on
    /// the bucket and has none left to narrow by.
    ///
    /// ```swift
    /// let p95 = try await store.query("request").percentile(0.95, of: "latency")
    /// ```
    ///
    public func percentile(_ rank: Double, of field: String) async throws -> Double? {
        try await percentiles.value(of: field, at: rank)
    }
}
