# Migrations

Every entity is described by a versioned `EntityDefinition` stored as a `SchemaDescriptor` record.
Definitions are immutable: a change is always a new version, published as a new record. A
record stores the `schema_version` it was written with, and the definition describes every
version at once (`since`/`until` bounds on fields) — so any record ever written stays
readable forever, and there is nothing to re-import.

## Declaring migrations

Declare each change as a `Migration` and run the list at startup:

```swift
struct CreatePurchase: Migration {
    func prepare(on store: EntityStore) async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .int)
            .field("date", .timestamp)
            .envelopeDate("date")
            .create()
    }
}

struct RetypePurchaseAmount: Migration {
    func prepare(on store: EntityStore) async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .double)      // int → double
            .field("date", .timestamp)
            .update()
    }
}

try await store.migrate([CreatePurchase(), RetypePurchaseAmount()])
```

Running the list twice is safe: republishing a version is an upsert, and backfills skip
records already at the latest version.

## What update() does

`update()` publishes the next version, diffed against the current one:

- a field declared with the same name and type **keeps its slot** — renames of the storage
  never happen behind your back;
- a field declared with a different type **moves to a fresh slot**; the old one closes at the
  new version and stays reserved while old records exist;
- a field you omit is **closed** (`until` = new version) — old records still decode it;
- a new field gets the next free slot with `since` = new version.

Settings (`envelopeDate`, `unique`, `views`, `keyID`, `ttl`) are inherited unless you set
them again.

## Renames

A rename is a close-plus-add from the builder's point of view. To keep the old values
readable under the new name, publish the definition manually with the storage carried over:

```swift
FieldDefinition(name: "user",    type: .string, storage: .slot(.string, "s_00"), until: 2),
FieldDefinition(name: "user_id", type: .string, storage: .slot(.string, "s_00"), since: 2),
```

Same slot, disjoint version ranges — reads at version 2 see `user_id`, reads of version-1
records see `user`, and a backfill carries the value across automatically.

## Backfill and rollback

Old records stay valid without any rewriting. To actively move them to the latest version:

```swift
let migrator = Migrator(database: database, registry: registry)
try await migrator.backfill(entity: "purchase") { record in
    if case .int(let cents)? = record.values["amount"] {
        record.values["amount"] = .double(Double(cents) / 100)
    }
}
```

Backfill is idempotent by construction — migrated records leave the query that feeds it — so
an interrupted run is safe to repeat. The `transform` closure handles type conversions;
renamed slot values carry over automatically.

Reverse migrations are the same operation pointed backwards: definitions describe every
version, so records can be re-encoded at an older version too. The only one-way door is data
a forward migration actually erased.

## Invariants

1. `SchemaDescriptor` versions are immutable — a change is always a new `entity_version`.
2. A slot is never reassigned while records of versions that used it still exist (the slot
   allocator and the definition validator both enforce this).
3. The physical `Schema` file never changes — see [Schema](schema.md).
