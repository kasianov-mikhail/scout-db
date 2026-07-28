# 📴 Offline

`OfflineCache` sits between `EntityStore` and the real `CKDatabase`: it queues writes and
replays cached reads when the network is down. It implements the same `CloudDatabase`
protocol as the real database, so wrapping it is the only integration step:

```swift
let cache = OfflineCache(backing: cloudDatabase, storeURL: cacheFileURL)
let store = EntityStore(database: cache, registry: registry)
```

## 📥 Offline reads and queued writes

`OfflineCache` caches the first page of every query it sees. On a transport failure — no
network, service unavailable — a read replays the last cached page, overlaid with anything
still queued locally, instead of throwing:

```swift
let purchases = try await store.read(entity: "purchase")   // served from cache offline
```

Reads by ID — `store.fetch(uuid:)`, `store.fetch(entity:uuids:)`, and the read half of every
`update`, `increment`, or `delete` — are answered the same way, from the merge baselines the
cache keeps of every record it has seen whole, overlaid with the queue. So a read-modify-write
completes offline instead of failing at its read:

```swift
try await store.update(entity: "purchase", uuid: "p-1") { $0.values["quantity"] = .int(9) }
```

An ID no baseline covers keeps throwing rather than reading as absent — answering "the server
has no such record" would turn an update into a create. For the same reason a multi-ID fetch
falls back only when the cache covers every ID asked for.

A write made while offline is queued and reported to the caller as if it had succeeded:

```swift
try await store.write(["quantity": .int(9)], entity: "purchase", uuid: "p-1")
print(cache.pendingWrites)   // 1, until the next successful flush
```

Continuation pages and conditional (compare-and-swap) saves are never cached or queued —
only the first page of plain reads and plain writes get this treatment. A batched
`update(entity:uuids:)` saves its records conditionally and so refuses offline, where a
single `update(entity:uuid:)` still queues.

## 🚧 What counts as offline

Besides the outright transport errors — `networkUnavailable`, `networkFailure`,
`serviceUnavailable`, and any `URLError` — the fallback also covers:

| Failure | Why |
|---|---|
| a request that outlived the 30s backstop timeout | a captive portal swallows requests instead of refusing them, so the caller is unblocked with a timeout, not a network error |
| `notAuthenticated`, `accountTemporarilyUnavailable` | iCloud is re-authenticating; the account comes back on its own, and a write queued meanwhile flushes then |
| any of the above wrapped as another error's underlying cause | CloudKit reports a transport failure nested as often as directly |

A queued write still needs a *live* flush eventually: an account that never returns leaves the
queue where it is, inspectable through `cache.queuedWrites`.

## 🔀 Flushing and conflicts

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

## 📏 Cache quotas

`OfflineCache(backing:storeURL:snapshotLimit:baselineLimit:conflictResolver:)` bounds both
caches with LRU eviction (`snapshotLimit: 50`, `baselineLimit: 500` by default). An evicted
snapshot loses offline coverage for that one query; an evicted baseline downgrades a
mergeable flush to a surfaced conflict rather than a silent correctness loss. Restarting the
app from a persisted `storeURL` restores entries as oldest — usage history isn't persisted.

## 📤 Outbox transactions and leases

`store.transaction { draft in ... }` writes a durable envelope record before applying its
steps and marks it committed after — an interrupted process resumes and finishes the
transaction on next launch (`store.repairTransactions(olderThan:)`) instead of leaving it
half-applied. A run of `draft.update(...)` steps is applied as one batch per entity, so a
transaction's patches cost the round trips of a single update rather than one update each.
Committed envelopes stay stored until you erase them with
`store.compactTransactions(olderThan:)` — run it past the horizon where a crashed writer
could still repair, or every device pays for the whole write history when it reads the entity.
`store.lease(entity:uuid:owner:for:)` is an advisory, compare-and-swap-based
lock for coordinating exclusive access across processes; it throws `SchemaError.leaseHeld`
if another owner already holds it.

## 🚦 Pacing requests

Every request ScoutDB sends passes a gate that keeps at most eight in flight at once, and a
rate limit or a busy zone is retried up to three times — after the server's own
`retryAfterSeconds` when it sends one, otherwise after a doubling wait with half of each
window randomized, so clients that met the limit together do not return together. A retry
gives its slot back before it waits, so a request sitting out a limit never holds the gate
closed behind it.

```swift
await RequestPolicy.setMaxConcurrentRequests(4)   // eight by default
```

Lower it when a long migration keeps meeting rate limits; raise it when the work is
latency-bound and the container is quiet.

## ⚠️ Limits

- `OfflineCache` is a best-effort local answer, not a replacement for the server: writes
  still need a live network eventually to actually flush, and a query the cache has never
  seen has nothing to replay.
- `store.lease(...)` taken offline is decided against a cached record, so it says nothing about
  what another process holds; it settles on `flush()`, as a landed write or a surfaced conflict.
- Conflict resolution only ever runs on `flush()` — a read never triggers it.
