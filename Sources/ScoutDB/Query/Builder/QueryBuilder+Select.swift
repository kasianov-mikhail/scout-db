//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Reads only the named fields of every record.
    ///
    /// The server leaves the other fields out of the response, so a read that
    /// needs a few small fields stops paying for the large ones. A record comes
    /// back with the selected fields and no others. Two fields come back even
    /// when the selection leaves them out: a sort field, and a field whose
    /// filter runs on the client. ``take(_:)``, ``first()`` and
    /// ``page(size:after:)`` honor the selection. An unknown field name throws
    /// when the query runs.
    ///
    /// ```swift
    /// let recent = try await store.query("purchase")
    ///     .sort("date", .reverse)
    ///     .select(["product_id", "amount"])
    ///     .take(20)
    /// ```
    ///
    public func select(_ fields: [String]) -> Self {
        var builder = self
        builder.selection = fields
        return builder
    }
}
