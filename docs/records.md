# Records

Beyond writing and querying fields, individual records carry files, references to other
entities, an optional audit trail, and a soft-delete lifecycle. This page covers those
capabilities; field encryption is covered in [Security](security.md) and materialized
aggregates in [Aggregation](aggregation.md).

## Table of Contents
- [Assets](#assets)
- [Relations](#relations)
- [Unique keys](#unique-keys)
- [Counters and set fields](#counters-and-set-fields)
- [Soft delete and restore](#soft-delete-and-restore)
- [Revisions](#revisions)

## Assets

Fields typed `.asset` (or `.assetList`) hold arbitrary bytes up to 50 MB. Hand a field bytes
directly — ScoutDB stages the upload to disk for you:

```swift
try await store.schema("report")
    .field("name", .string, .required)
    .field("dump", .asset)
    .create()

try await store.write(["name": .string("crash"), "dump": .bytes(logData)],
                       entity: "report", uuid: "r-1")
```

Staged files are content-addressed by hash, so retrying the same write reuses the same file
instead of duplicating it, and an interrupted write never leaves an orphaned copy mid-upload.
Concurrent writes carrying the same bytes share that one file, and it is retired only once the
last of them lands — the first to finish never pulls it out from under the others.
Read a written asset back promptly — the URL CloudKit hands back points into its own
transient cache:

```swift
let record = try await store.fetch(entity: "report", uuids: ["r-1"]).first!
let bytes = try record.assetData(for: "dump")
```

A write that never lands (abandoned mid-retry, or failed at the server) can still leave a staged
file behind. Sweep those periodically:

```swift
let removed = EntityStore.sweepStagedAssets(olderThan: 86_400)   // default: 24h
```

## Relations

Declare a reference field with `.references(_:)` (one parent) or `.exclusiveReference(_:)`
(one parent, enforced unique holder):

```swift
.field("order_id", .string, .references("order"))
```

Resolve references without N+1 queries:

```swift
let parents = try await store.join(entity: "order", records: purchases, field: "order_id")
// [uuid: EntityRecord] — one lookup for every purchase's order

let byField = try await store.join(entity: "order", records: purchases,
                                    fields: ["order_id", "warehouse_id"])

let chain = try await store.join(entity: "order", records: purchases,
                                  path: ["order_id", "customer_id"])
```

The reverse direction:

```swift
let lineItems = try await store.children(entity: "purchase", of: order, via: "order_id")

try await store.delete(entity: "order", uuid: "o-1", cascade: true)
// scalar references to o-1 are deleted; list references are detached, not deleted
```

Construct the store with `enforceReferences: true` to reject writes that would create a
dangling reference, and to enforce `.exclusiveReference` uniqueness:

```swift
let store = EntityStore(database: database, registry: registry, enforceReferences: true)
```

A write whose reference field names no live parent throws `SchemaError.brokenReference`. Both
checks are client-side — useful as a guardrail, not a server-side constraint.

## Unique keys

`.unique(on:)` makes writes upsert by identity. A `uniqueKey(on:)` is different: it rejects a
write that would duplicate another **live** record's values for that field tuple, without
changing write semantics:

```swift
try await store.schema("account")
    .field("email", .string, .required)
    .field("username", .string)
    .uniqueKey(on: "email")
    .uniqueKey(on: "username")
    .create()
```

Declare one per independent key, as above — an email and a username constrain separately. A
duplicate throws `SchemaError.duplicateKey(fields:)`. Records missing a key field are
exempt, and tombstoning a record frees its key.

A key of several fields constrains the tuple rather than each field, so a membership admits
a group twice and a member twice, but the pair once:

```swift
try await store.schema("membership")
    .field("group_id", .string, .required)
    .field("member", .string, .required)
    .uniqueKey(on: "group_id", "member")
    .create()
```

The constraint holds under a race. Every value is held by its own claim record, named
after the value so that all writers of that value contend for the same record, and winning
it is a compare-and-swap on the server: of two writers racing for one value exactly one
lands and the other throws. The claim is reached by name rather than by query, so the key
needs no slot-backed field and never waits on the query index.

That costs a keyed fetch and a conditional save per write batch, plus one claim record per
value, released when the record is deleted or re-keyed. Declaring a key over existing data
leaves the old values unclaimed until you run `Migrator.backfillClaims(entity:)` once;
until that pass finishes, an old value can still be re-taken.

| Declaration | Guarantee |
|---|---|
| `unique(on:)` | derives the record's identity, so a repeat write upserts rather than duplicates |
| `uniqueKey(on:)` | claim-backed compare-and-swap, so a race for one value seats one writer |
| `enforceReferences: true` | advisory: the parent is checked before the write, and can be deleted right after |

## Counters and set fields

Atomic per-record mutation, distinct from the aggregate views in
[Aggregation](aggregation.md) — this updates the record's own field in place, safely under
concurrent writers:

```swift
let total = try await store.increment(entity: "product", uuid: "p-1", field: "stock", by: -1)
let tags  = try await store.insert(["sale"], into: "tags", entity: "product", uuid: "p-1")
try await store.remove(["clearance"], from: "tags", entity: "product", uuid: "p-1")
```

Never call `increment` inside a `transaction` — transaction replays are at-least-once, and a
replayed increment would double-count.

## Soft delete and restore

Every record's envelope carries a `deleted` flag (see [Schema](schema.md#envelope)).
The lifecycle API around it:

| Method | Effect |
|---|---|
| `delete(entity:uuid:)` | tombstone; values retained |
| `restore(entity:uuid:)` | lift the tombstone |
| `compact(entity:olderThan:)` | permanently erase old tombstones |
| `compactTransactions(olderThan:)` | erase committed transaction envelopes |
| `compactRevisions(olderThan:of:)` | trim the revision log to a window |
| `drop(entity:)` | tombstone every record, retire the schema |

```swift
try await store.delete(entity: "purchase", uuid: "p-1")
try await store.restore(entity: "purchase", uuid: "p-1")
try await store.compact(entity: "purchase", olderThan: cutoff)
try await store.drop(entity: "purchase")
```

`compact` erases tombstones for good — a record purged this way can no longer be restored.

## Revisions

An opt-in, append-only audit log — not the mechanism behind optimistic concurrency, which is
CloudKit's own change tag. Enable it per entity, then read history oldest-first:

```swift
try await registry.publish(EntityStore.revisionDefinition)   // once, like the schema registry itself

try await store.schema("purchase")
    .field("product_id", .string, .required)   // …and every other field the entity still has
    .audited()
    .update()

let history = try await store.history(entity: "purchase", uuid: "p-1")
// each element is the record's state right before an update or delete overwrote it
```

`update()` publishes a whole version, so a field the call leaves out is closed — redeclare
them all alongside `.audited()`. The flag itself carries to later versions that don't mention
it, like the other settings.

The log only grows, and `_rev` records are stored records like any other, so an audited
entity's history soon outweighs its data. Trim it to the window you actually answer questions
about:

```swift
try await store.compactRevisions(olderThan: .now.addingTimeInterval(-90 * 24 * 3_600))
try await store.compactRevisions(olderThan: cutoff, of: "purchase")   // one entity only
```

Compacted revisions are erased, not tombstoned — they are gone from `history` for good.
