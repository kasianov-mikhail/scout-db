//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One schema change, Fluent-style: publish definitions in `prepare`, undo
/// them in `revert`.
///
/// ```swift
/// struct CreatePurchase: Migration {
///     func prepare(on store: UniversalStore) async throws {
///         try await store.schema("purchase")
///             .field("product_id", .string, .required)
///             .field("date", .timestamp)
///             .envelopeDate("date")
///             .create()
///     }
/// }
/// ```
///
/// Migrations are idempotent by construction — republishing a version is an
/// upsert, and backfills skip records already at the latest version — so
/// running the same list twice is safe.
///
public protocol Migration: Sendable {
    /// Applies the change: publish a definition, backfill records.
    func prepare(on store: UniversalStore) async throws

    /// Undoes the change; the default does nothing.
    func revert(on store: UniversalStore) async throws
}

extension Migration {
    public func revert(on store: UniversalStore) async throws {}
}

extension UniversalStore {
    /// Runs every migration in order.
    public func migrate(_ migrations: [any Migration]) async throws {
        for migration in migrations {
            try await migration.prepare(on: self)
        }
    }

    /// Reverts the migrations in reverse order.
    public func revert(_ migrations: [any Migration]) async throws {
        for migration in migrations.reversed() {
            try await migration.revert(on: self)
        }
    }
}
