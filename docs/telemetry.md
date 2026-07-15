# 📈 Telemetry

ScoutDB throttles, retries, and times out CloudKit requests so your app doesn't have to. A
per-call observer makes that traffic observable instead of opaque: durations, record counts,
and errors for every operation.

## 👀 Per-call observer

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

| Property | Meaning |
|---|---|
| `operation.kind` | `query`, `continuation`, `save`, `modify`, `conditionalSave`, subscription and zone operations, `fetch`, `zoneChanges`, `databaseChanges` |
| `operation.recordCount` | result count for reads, input count for writes |
| `operation.error` | `nil` on success |

`record(_:)` runs synchronously on the calling task — hand work off to your own queue rather
than doing anything slow inside it.

Wrap whichever layer you want visibility into: wrapping the raw database sees every wire
call including ones the offline/replica caches serve locally; wrapping `OfflineCache` sees
only what actually reaches CloudKit.

## 🔕 Failures that used to be silent

A few failure paths that previously dropped their error on the floor now surface it:

- **Background sync ticks.** `SyncCoordinator`'s periodic passes and push-triggered passes
  used to swallow a failed sync silently. Pass `onError:` at construction to hear about it:

  ```swift
  let coordinator = SyncCoordinator(store: store, tokenURL: tokenURL,
                                     onError: { print("sync failed:", $0) })
  ```

  A `sync()` call you `await` directly still throws normally — `onError` only covers the
  passes the coordinator runs on its own (`start(every:)`, `handlePush(_:)`).

- **Partial batch writes.** A batch `write(records:)` that partially fails now throws
  `PartialWriteError`, keyed by record ID, with only the failures that actually caused the
  rollback.

- **Malformed filter patterns.** A `.like`/`.matches` filter with an invalid regex used to
  compile into a predicate that silently matched nothing. It now throws
  `SchemaError.invalidValue(field)` instead of returning an empty result set for a typo.

## ✅ What you don't need to configure

Rate limiting, retries on throttling, and request timeouts are handled automatically for
typical use — the telemetry above is how you'd notice if either is actually the bottleneck. A
request that times out surfaces as `RequestTimeoutError`.
