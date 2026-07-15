# Records

Beyond writing and querying fields, individual records carry files, references to other
entities, an optional audit trail, and soft-delete/TTL lifecycle. This page covers those
capabilities; field encryption is covered in [Security](security.md) and materialized
aggregates in [Aggregation](aggregation.md).

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

The reverse direction and integrity checks:

```swift
let lineItems = try await store.children(entity: "purchase", of: order, via: "order_id")
let dangling  = try await store.orphans(entity: "purchase", field: "order_id")

try await store.delete(entity: "order", uuid: "o-1", cascade: true)
// scalar references to o-1 are deleted; list references are detached, not deleted
```

Turn on `EntityStore.enforceReferences` to reject writes that would create a dangling
reference, and to enforce `.exclusiveReference` uniqueness. Both checks are client-side —
useful as a guardrail, not a server-side constraint.

## Unique keys

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

## Soft delete, restore, and TTL

Every record's envelope carries `deleted` and `expires` (see [Schema](schema.md#envelope)).
The lifecycle API around them:

```swift
try await store.delete(entity: "purchase", uuid: "p-1")     // tombstone; values retained
try await store.restore(entity: "purchase", uuid: "p-1")     // lift the tombstone
try await store.compact(entity: "purchase", olderThan: cutoff)  // permanently erase old tombstones
try await store.drop(entity: "purchase")                     // tombstone every record, retire the schema
```

`compact` removes tombstones from the change feed for good — a record purged this way can no
longer be restored. TTL is declared with `.ttl(_ seconds:)` on the schema; expired records
are purged with:

```swift
try await store.reap(entity: "purchase", asOf: .now)
```

## Revisions

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
