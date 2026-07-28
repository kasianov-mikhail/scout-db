# 📎 Records

Beyond writing and querying fields, individual records carry files, references to other
entities, an optional audit trail, and soft-delete/TTL lifecycle. This page covers those
capabilities; field encryption is covered in [Security](security.md) and materialized
aggregates in [Aggregation](aggregation.md).

## 📁 Assets

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

A write that never lands (queued offline, or abandoned mid-retry) can still leave a staged
file behind. Sweep those periodically:

```swift
let removed = EntityStore.sweepStagedAssets(olderThan: 86_400)   // default: 24h
```

## 🔗 Relations

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

The reverse direction and integrity checks:

```swift
let lineItems = try await store.children(entity: "purchase", of: order, via: "order_id")
let dangling  = try await store.orphans(entity: "purchase", field: "order_id")

try await store.delete(entity: "order", uuid: "o-1", cascade: true)
// scalar references to o-1 are deleted; list references are detached, not deleted
```

`orphans` is a whole-entity sweep: it reads the entity, then asks the server which of the
parents its records name are still live. The cost follows the entity's size and its distinct
parent count, not the number of orphans found — pass `fields:` to trim what it reads back,
and run it as an occasional integrity check rather than on a screen.

Turn on `EntityStore.enforceReferences` to reject writes that would create a dangling
reference, and to enforce `.exclusiveReference` uniqueness. Both checks are client-side —
useful as a guardrail, not a server-side constraint.

## 🔑 Unique keys

`.unique(on:)` makes writes upsert by identity. A `uniqueKey(on:)` is different: it rejects a
write that would duplicate another **live** record's values for that field tuple, without
changing write semantics:

```swift
try await store.schema("account")
    .field("email", .string, .required)
    .uniqueKey(on: "email")
    .create()
```

A duplicate throws `SchemaError.duplicateKey(fields:)`. Records missing a key field are
exempt, and tombstoning a record frees its key. Like reference enforcement, this is a
client-side pre-write check — two writers racing on the same key can still both win.

`enforcedKey(on:)` is the one that holds under a race:

```swift
try await store.schema("account")
    .field("email", .string, .required)
    .enforcedKey(on: "email")
    .create()
```

Each key value is held by its own claim record, and winning that claim is a
compare-and-swap on the server, so of two writers racing on the same value exactly one
lands and the other throws. Declaring it over existing data leaves the old values
unclaimed until you run `Migrator.backfillClaims(entity:)` once — until that pass
finishes, an old value can still be re-taken.

| Declaration | Guarantee |
|---|---|
| `unique(on:)` | derives the record's identity, so a repeat write upserts rather than duplicates |
| `uniqueKey(on:)` | advisory: validated by a read before the write, so a race can seat two |
| `enforcedKey(on:)` | atomic: claim-backed compare-and-swap, so a race seats one |
| `EntityStore.enforceReferences` | advisory: the parent is checked before the write, and can be deleted right after |

Reach for `enforcedKey(on:)` when a duplicate would be a correctness problem, and for
`uniqueKey(on:)` when it would merely be untidy — the claim costs a fetch and a
conditional save per write batch.

## 🔢 Counters and set fields

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

## 🗑️ Soft delete, restore, and TTL

Every record's envelope carries `deleted` and `expires` (see [Schema](schema.md#envelope)).
The lifecycle API around them:

| Method | Effect |
|---|---|
| `delete(entity:uuid:)` | tombstone; values retained |
| `restore(entity:uuid:)` | lift the tombstone |
| `compact(entity:olderThan:)` | permanently erase old tombstones |
| `compactTransactions(olderThan:)` | erase committed transaction envelopes |
| `compactRevisions(olderThan:of:)` | trim the revision log to a window |
| `drop(entity:)` | tombstone every record, retire the schema |
| `reap(entity:asOf:)` | purge TTL-expired records |

```swift
try await store.delete(entity: "purchase", uuid: "p-1")
try await store.restore(entity: "purchase", uuid: "p-1")
try await store.compact(entity: "purchase", olderThan: cutoff)
try await store.drop(entity: "purchase")
```

`compact` erases tombstones for good — a record purged this way can no longer be restored. TTL is declared with `.ttl(_ seconds:)` on the schema; expired records
are purged with:

```swift
try await store.reap(entity: "purchase", asOf: .now)
```

## 📜 Revisions

An opt-in, append-only audit log — not the mechanism behind optimistic concurrency, which is
CloudKit's own change tag. Enable it per entity, then read history oldest-first:

```swift
try await registry.publish(EntityStore.revisionDefinition)   // once, like the schema registry itself

var definition = try await registry.definition(for: "purchase")
definition.audited = true
try await registry.publish(definition)

let history = try await store.history(entity: "purchase", uuid: "p-1")
// each element is the record's state right before an update or delete overwrote it
```

The log only grows, and `_rev` records are stored records like any other — a device building a
replica pays for the whole history. Trim it to the window you actually answer questions about:

```swift
try await store.compactRevisions(olderThan: .now.addingTimeInterval(-90 * 24 * 3_600))
try await store.compactRevisions(olderThan: cutoff, of: "purchase")   // one entity only
```

Compacted revisions are erased, not tombstoned — they are gone from `history` for good.
