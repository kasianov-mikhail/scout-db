//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A chainable schema builder that assigns slots and versions automatically.
///
/// ```swift
/// try await store.schema("purchase")
///     .field("product_id", .string, .required)
///     .field("amount", .double)
///     .field("date", .timestamp)
///     .field("comment", .string, .payload)
///     .unique(on: "product_id", "date")
///     .create()
/// ```
///
/// `update()` publishes the next version: unchanged fields keep their slots,
/// retyped fields move to a fresh slot, and omitted fields are closed — old
/// records remain readable through their own version forever.
///
public struct SchemaBuilder {
    let entity: String
    let registry: SchemaRegistry

    var declarations: [Declaration] = []
    var unique: [String]?
    var uniqueKeys: [[String]]?
    var views: [AggregateView] = []
    var keyID: String?
    var audited: Bool?

    init(entity: String, registry: SchemaRegistry) {
        self.entity = entity
        self.registry = registry
    }

    /// Derives the record id from the named fields, turning writes into
    /// upserts.
    ///
    /// The id is a digest of those values, so writing the same combination
    /// twice rewrites one record rather than making a second — and a write
    /// missing any of the fields is rejected. The uuid a caller passes is
    /// ignored, since identity comes from the values.
    ///
    /// ```swift
    /// try await store.schema("reading")
    ///     .field("sensor", .string, .required)
    ///     .field("taken", .timestamp, .required)
    ///     .unique(on: "sensor", "taken")
    ///     .create()
    /// ```
    ///
    public func unique(on fields: String...) -> Self {
        var builder = self
        builder.unique = fields
        return builder
    }

    /// Adds a uniqueness constraint over the named fields.
    ///
    /// A key of several fields constrains the tuple, not each field: a
    /// membership keyed on `group_id` and `member` admits a group twice and a
    /// member twice, but the pair once.
    ///
    /// Unlike `unique(on:)`, which derives the record's identity, a unique key
    /// only rejects writes that would duplicate another live record's values —
    /// declare several for independent keys (an email and a username). Records
    /// missing any of the key's fields are exempt, and tombstoning a record
    /// frees its values.
    ///
    /// Every value is held by a claim record named after it, taken with a
    /// compare-and-swap, so of two writers racing for one value exactly one
    /// lands and the other fails with `duplicateKey`. The claim costs a keyed
    /// fetch and a conditional save per write batch and is released when the
    /// record is deleted or re-keyed. Existing data needs one
    /// `Migrator.backfillClaims(entity:)` pass before the constraint holds.
    ///
    /// ```swift
    /// try await store.schema("account")
    ///     .field("email", .string, .required)
    ///     .field("username", .string, .required)
    ///     .uniqueKey(on: "email")
    ///     .uniqueKey(on: "username")
    ///     .create()
    /// ```
    ///
    public func uniqueKey(on fields: String...) -> Self {
        var builder = self
        builder.uniqueKeys = (uniqueKeys ?? []) + [fields]
        return builder
    }

    /// Names the encryption key that seals `.encrypted` fields and backs
    /// `hmac` derivations.
    ///
    /// The name is published with the schema; the key itself is resolved on the
    /// device through the store's `EncryptionKeyProvider`, so it never leaves
    /// it. Declaring either an encrypted field or an `hmac` shadow without this
    /// is rejected at publish time.
    ///
    /// ```swift
    /// try await store.schema("account")
    ///     .field("token", .string, .payload, .encrypted)
    ///     .keyID("account-key")
    ///     .create()
    /// ```
    ///
    public func keyID(_ keyID: String) -> Self {
        var builder = self
        builder.keyID = keyID
        return builder
    }

    /// Appends a revision record on every update and delete of the entity.
    ///
    /// Trim the log with `compactRevisions(olderThan:of:)` — every entry is a
    /// record of its own. An `update()` that does not call this keeps whatever
    /// the previous version declared.
    ///
    /// ```swift
    /// try await store.schema("ledger")
    ///     .field("amount", .double, .required)
    ///     .audited()
    ///     .create()
    ///
    /// let history = try await store.history(entity: "ledger", uuid: "l-1")
    /// ```
    ///
    public func audited(_ audited: Bool = true) -> Self {
        var builder = self
        builder.audited = audited
        return builder
    }
}

extension EntityStore {
    /// Opens a chained schema declaration for an entity.
    ///
    /// Nothing reaches the database until ``SchemaBuilder/create()`` or
    /// ``SchemaBuilder/update()`` publishes it, so the builder is a value to
    /// hold and pass around. Slots and versions are assigned for you — the
    /// declaration names fields and rules, never storage.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("date", .timestamp)
    ///     .create()
    /// ```
    ///
    public func schema(_ entity: String) -> SchemaBuilder {
        SchemaBuilder(entity: entity, registry: registry)
    }
}
