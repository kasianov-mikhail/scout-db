# 🧰 Operations

What surrounds the reads and writes themselves: durable multi-step work, the gate every
request passes through, and the hook that reports what each call cost.

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

## 📈 Telemetry

`ObservedDatabase` is a `CloudDatabase` decorator that reports every settled call — kind,
duration, record count, and the error if it threw — to an observer of yours:

```swift
let observed = ObservedDatabase(backing: cloudDatabase, observer: MyObserver())
let store = EntityStore(database: observed, registry: registry)
```

Where you wrap decides what you measure: around a `CKDatabase` it sees wire calls, around a
decorator of your own it sees what the app experiences. `record(_:)` is called synchronously
on the calling task, so hand the operation off to a logger or a metrics pipeline rather than
blocking in it.
