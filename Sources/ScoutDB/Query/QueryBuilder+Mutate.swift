//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension QueryBuilder {
    /// Rewrites every matching record through the transform, and returns how
    /// many were written.
    ///
    /// The sweep pages through the query and writes each page before reading the
    /// next, so it holds a page rather than the whole result. Each record is
    /// saved under a compare-and-swap and retried on conflict, so a concurrent
    /// writer costs a retry rather than a lost update.
    ///
    /// ```swift
    /// let moved = try await store.query("purchase")
    ///     .filter("status" == "placed")
    ///     .update { $0.values["status"] = .string("paid") }
    /// ```
    ///
    @discardableResult public func update(_ transform: (inout EntityRecord) throws -> Void) async throws -> Int {
        try await store.updateAll(
            entity: entity,
            any: alternatives,
            createdBy: creator,
            transform: transform
        )
    }

    /// Tombstones every matching record, and returns how many were deleted.
    ///
    /// A delete is a tombstone: the record leaves every query but its row stays
    /// behind, so a later write to the same uuid sees it. The sweep pages
    /// through the query the way ``update(_:)`` does.
    ///
    /// ```swift
    /// let dropped = try await store.query("purchase")
    ///     .filter("date" < cutoff)
    ///     .delete()
    /// ```
    ///
    @discardableResult public func delete() async throws -> Int {
        try await store.deleteAll(
            entity: entity,
            any: alternatives,
            createdBy: creator
        )
    }
}
