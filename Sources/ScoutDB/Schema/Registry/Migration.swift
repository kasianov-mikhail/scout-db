//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One schema change: publish definitions in `prepare`, undo them in `revert`.
///
/// ```swift
/// struct CreatePurchase: Migration {
///     func prepare(on store: EntityStore) async throws {
///         try await store.schema("purchase")
///             .field("product_id", .string, .required)
///             .field("date", .timestamp)
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
    ///
    /// Publish through `SchemaBuilder` — `create()` for the first version of an
    /// entity, `update()` for every one after. Publishing alone rewrites
    /// nothing: records keep the version they were written under and stay
    /// readable through it, so a change that has to reach existing records
    /// needs `Migrator.backfill(entity:)` after the publish, and a fresh
    /// `count(by:)` needs `Migrator.backfill(aggregate:entity:)` to cover the
    /// records that landed before the cell existed.
    ///
    /// ``EntityStore/migrate(_:)`` awaits each call before it starts the next,
    /// so a migration sees everything the ones ahead of it published.
    ///
    func prepare(on store: EntityStore) async throws

    /// Undoes the change; the default does nothing.
    ///
    /// Write it for what a store can actually give back — records the
    /// migration seeded, a value it filled in — and leave the default in place
    /// otherwise. A published version is not one of those: the registry only
    /// ever publishes versions, so the way back from a schema mistake is a
    /// further version that spells the shape out again.
    ///
    func revert(on store: EntityStore) async throws
}

extension Migration {
    public func revert(on _: EntityStore) async throws {}
}

extension EntityStore {
    /// Runs every migration in order.
    ///
    /// The list is the entity's history rather than a set of pending work: it
    /// keeps every migration ever written, and running it against an empty
    /// database walks the same path a live one already walked.
    ///
    /// Nothing wraps the run in a transaction. A migration that throws stops
    /// the walk and leaves the ones ahead of it applied, so the fix is to
    /// correct the failing migration and run the same list again. That re-run
    /// costs little and changes nothing already in place — `create()`
    /// republishes version 1 over itself, and a backfill only visits records
    /// left behind an earlier version. An `update()`, though, always publishes
    /// the next version, so a second run of the same list adds a version of the
    /// same shape: harmless to how records read, but not a no-op.
    ///
    /// ```swift
    /// try await store.migrate([CreatePurchase(), AddPurchaseStatus()])
    /// ```
    ///
    public func migrate(_ migrations: [any Migration]) async throws {
        for migration in migrations {
            try await migration.prepare(on: self)
        }
    }

    /// Reverts the migrations in reverse order.
    ///
    /// Newest first, so a migration is undone only after everything built on
    /// top of it is gone. Pass the same list ``migrate(_:)`` was given —
    /// migrations that never override `revert(on:)` fall through the default
    /// and cost nothing but the call.
    ///
    /// Reverting is not a rollback of the schema itself: versions only move
    /// forward, and a migration takes back only what its own `revert(on:)`
    /// spells out. Like the forward run, this one has no transaction around it
    /// and stops at the first throw.
    ///
    public func revert(_ migrations: [any Migration]) async throws {
        for migration in migrations.reversed() {
            try await migration.revert(on: self)
        }
    }
}
