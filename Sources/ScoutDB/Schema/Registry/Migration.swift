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
/// Migrations touch no records: publishing a version is an upsert over the
/// record the registry keeps it under, so running the same list twice leaves
/// the data exactly where it was.
///
public protocol Migration: Sendable {
    /// Applies the change: publishes a definition.
    ///
    /// Publish through `SchemaBuilder` — `create()` for the first version of an
    /// entity, `update()` for every one after. Publishing rewrites nothing:
    /// records keep the version they were written under and stay readable
    /// through it, so a field a later version renamed or retyped still decodes
    /// out of the older records under the name it carried there.
    ///
    /// What a version does not reach is the server's view of those records. A
    /// filter or a sort names the slot the current version holds a field in, so
    /// records left behind an earlier one answer only through the fields whose
    /// slot never moved. An aggregate is bounded the same way: a cell counts
    /// what lands after it, never what came before.
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
    /// correct the failing migration and run the same list again. No record is
    /// touched either way, and `create()` republishes version 1 over itself. An
    /// `update()`, though, always publishes the next version, so a second run
    /// of the same list adds a version of the same shape: harmless to how
    /// records read, but not a no-op.
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
