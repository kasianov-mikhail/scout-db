# Telemetry

ScoutDB throttles, retries, and times out CloudKit requests internally. Two seams make that
traffic observable instead of opaque: an in-flight request counter for at-a-glance backpressure,
and a per-call observer for durations, record counts, and errors.

## In-flight request count

Every CloudKit request ScoutDB issues is gated through a shared limiter; its current
concurrency is published as an `AsyncStream`:

```swift
Task {
    for await count in cloudKitRequestActivity.updates {
        print("CloudKit in-flight requests: \(count)")
    }
}
```

A new subscriber immediately receives the current count, then every change after that.
Multiple subscribers are independent — each gets its own stream.

## Per-call observer

Wrap any `CloudDatabase` layer — the raw CloudKit database, or a decorator like `OfflineCache`
— to see every operation that flows through it:

```swift
struct MetricsObserver: DatabaseObserver {
    func record(_ operation: DatabaseOperation) {
        print("\(operation.kind) took \(operation.duration), " +
              "\(operation.recordCount) record(s), error: \(operation.error ?? "none")")
    }
}

let observed = ObservedDatabase(backing: container.privateCloudDatabase, observer: MetricsObserver())
let store = EntityStore(database: observed, registry: registry)
```

`DatabaseOperation.kind` distinguishes `query`, `continuation`, `save`, `modify`,
`conditionalSave`, the subscription and zone operations, `fetch`, `zoneChanges`, and
`databaseChanges`. `recordCount` is result count for reads and input count for writes;
`error` is `nil` on success. `record(_:)` runs synchronously on the calling task — hand work
off to your own queue rather than doing anything slow inside it.

Wrap whichever layer you want visibility into: wrapping the raw database sees every wire
call including ones the offline/replica caches serve locally; wrapping `OfflineCache` sees
only what actually reaches CloudKit.

## Failures that used to be silent

A few failure paths that previously dropped their error on the floor now surface it:

- **Background sync ticks.** `SyncCoordinator`'s periodic passes and push-triggered passes
  used to swallow a failed sync silently. Pass `onError:` at construction to hear about it:

  ```swift
  let coordinator = SyncCoordinator(store: store, tokenURL: tokenURL,
                                     onError: { print("sync failed:", $0) })
  ```

  A `sync()` call you `await` directly still throws normally — `onError` only covers the
  passes the coordinator runs on its own (`start(every:)`, `handlePush(_:)`).

- **Partial batch writes.** A batch `write(records:)` that partially fails used to surface
  CloudKit's raw `.partialFailure`, with the actual per-record cause buried in `userInfo`.
  It now throws `PartialWriteError`, keyed by record ID, with only the failures that actually
  caused the rollback (placeholders filtered out).

- **Malformed filter patterns.** A `.like`/`.matches` filter with an invalid regex used to
  compile into a predicate that silently matched nothing. It now throws
  `SchemaError.invalidValue(field)` instead of returning an empty result set for a typo.

## Rate limiting and timeouts

CloudKit concurrency is capped internally (`cloudKitParallelismLimit = 8`) and a
`.requestRateLimited`/`.zoneBusy` error is retried automatically using CloudKit's own
`retryAfterSeconds` hint, up to 3 attempts. Every request also races a 30-second timeout
above CloudKit's own request timeout, surfaced as `RequestTimeoutError(seconds:)` if it fires.
None of this needs configuration for typical use — the telemetry above is how you'd notice if
it's actually the bottleneck.
