# Offline

Two decorators sit between `EntityStore` and the real `CKDatabase`, and compose in either
order: `OfflineCache` queues writes and replays cached reads when the network is down;
`ReplicaCache` mirrors whole zones so reads can be answered locally on purpose, not just as a
fallback. Both implement the same `CloudDatabase` protocol as the real database, so wrapping
one is the only integration step:

```swift
let cache = OfflineCache(backing: cloudDatabase, storeURL: cacheFileURL)
let replica = ReplicaCache(backing: cache, zoneID: zoneID)
let store = EntityStore(database: replica, registry: registry)
```

## Offline reads and queued writes

`OfflineCache` caches the first page of every query it sees. On a transport failure — no
network, service unavailable — a read replays the last cached page, overlaid with anything
still queued locally, instead of throwing:

```swift
let purchases = try await store.read(entity: "purchase")   // served from cache offline
```

A write made while offline is queued and reported to the caller as if it had succeeded:

```swift
try await store.write(["quantity": .int(9)], entity: "purchase", uuid: "p-1")
print(cache.pendingWrites)   // 1, until the next successful flush
```

Continuation pages and conditional (compare-and-swap) saves are never cached or queued —
only the first page of plain reads and plain writes get this treatment.

## Flushing and conflicts

```swift
do {
    try await cache.flush()
} catch let error as OfflineFlushError {
    for conflict in error.conflicts {
        // conflict.queued vs conflict.server
    }
}
```

Each queued save replays under compare-and-swap. If the server record changed underneath it,
`flush()` first tries a field-level merge — grafting the queued edit onto the new server
record, but only if the two sides changed disjoint fields relative to the last known
baseline. Overlapping edits fall to an app-supplied resolver:

```swift
cache.setConflictResolver(store.conflictResolver { queued, server, ancestor in
    var merged = server
    let mine: Int64 = queued["quantity"] ?? 0
    let theirs: Int64 = server["quantity"] ?? 0
    merged.values["quantity"] = .int(max(mine, theirs))
    return .save(merged)
})
```

`store.conflictResolver` bridges schema field names onto the raw `CKRecord` resolver
`OfflineCache` expects, so `queued`/`server` subscript by field name and an encrypted field
carries over correctly if you return `.save`. Without a resolver — or when one returns
`.surface` — the write is dequeued and reported in `OfflineFlushError.conflicts` instead of
silently lost or silently overwritten.

## Cache quotas

`OfflineCache(backing:storeURL:snapshotLimit:baselineLimit:conflictResolver:)` bounds both
caches with LRU eviction (`snapshotLimit: 50`, `baselineLimit: 500` by default). An evicted
snapshot loses offline coverage for that one query; an evicted baseline downgrades a
mergeable flush to a surfaced conflict rather than a silent correctness loss. Restarting the
app from a persisted `storeURL` restores entries as oldest — usage history isn't persisted.

## Zone replicas

`ReplicaCache` mirrors one or more zones and serves queries from the mirror directly, rather
than only on failure:

```swift
let replica = ReplicaCache(backing: cache, zoneID: zoneID, readPolicy: .localFirst)
try await replica.refresh()   // walk the zone feed to completion once
```

- `readPolicy: .networkFirst` (default) — hit the mirror only when the network fails, same
  posture as `OfflineCache`.
- `readPolicy: .localFirst` — serve replicated zones from the mirror immediately, once
  `refresh()` (or an ordinary `SyncCoordinator` pass) has drained that zone completely.
- `fields:` — mirror a whitelist of fields instead of whole records (pair with the same
  `SyncProjection` used for [selective sync](sync.md#selective-sync)). A partial replica only
  answers a query locally if the whitelist covers every field the query filters, sorts, or
  projects on; otherwise it falls through to the network rather than returning wrong results.

The local query path (`LocalQuery`/`PredicateEvaluator`) supports the comparison operators,
compound predicates, distance queries, and the token-based full-text search the query builder
generates — anything it doesn't recognize makes a *partial* replica refuse to answer locally
(a full replica always answers, since there's nothing it could be missing).

## Outbox transactions and leases

`store.transaction { draft in ... }` writes a durable envelope record before applying its
steps and marks it committed after — an interrupted process resumes and finishes the
transaction on next launch (`store.repairTransactions(olderThan:)`) instead of leaving it
half-applied. `store.lease(entity:uuid:owner:for:)` is an advisory, compare-and-swap-based
lock for coordinating exclusive access across processes; it throws `SchemaError.leaseHeld`
if another owner already holds it.

## Limits

- `OfflineCache` and `ReplicaCache` are best-effort local answers, not a replacement for the
  server: writes still need a live network eventually to actually flush.
- A partial replica's un-mirrored fields decode as `nil` — don't write a partial record back
  whole, same caveat as a projected sync delta.
- Conflict resolution only ever runs on `flush()` — a read never triggers it.
