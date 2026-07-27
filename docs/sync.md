# 📡 Sync

CloudKit's zone change feed is the only way to discover what changed without re-querying
everything. ScoutDB decodes that feed into typed items, walks it in resumable batches, and
wires it to push notifications and SwiftUI so a view updates itself when data changes
anywhere — locally or on another device.

## 📖 Reading the change feed

```swift
let delta = try await store.zoneChanges(since: savedToken)
```

| Field | Holds |
|---|---|
| `delta.records` | `[EntityRecord]` — changed and tombstoned records |
| `delta.deleted` | `[String]` — hard-deleted uuids |
| `delta.token` | `Data?` — persist this, pass it back next time |

`since: nil` replays the zone from the beginning. `changes(entity:since:)` narrows the same
feed to one entity — the cost still scales with what changed, not with the entity's size.
Decode into typed items instead of raw records:

```swift
let purchases: [Purchase] = delta.items(Purchase.self)
let removedIDs: [String] = delta.deletedIDs(of: Purchase.self)
```

## 📦 Batched walking with progress

A large backlog shouldn't be one unbounded round trip. Ask for a stream of deltas instead,
one per batch, each carrying its own resumable token:

```swift
for try await batch in store.zoneChanges(since: savedToken, batchSize: 200) {
    apply(batch)
    savedToken = batch.token   // safe to persist after every batch
}
```

`SyncCoordinator` wraps this loop: construct it with a `batchSize` and its `sync()` walks the
whole feed batch by batch, persisting the token and reporting a running count as it goes:

```swift
let coordinator = SyncCoordinator(
    store: store,
    tokenURL: tokenURL,          // persists the zone token across launches
    onError: { print("sync error:", $0) }
)
coordinator.start(every: .seconds(300)) { delta in
    print("synced \(delta.records.count) changes")
}
```

A killed sync resumes mid-feed rather than restarting — each batch's token is persisted
before the next batch is fetched.

## 🎯 Selective sync

Pull only the fields a view actually needs instead of full payloads and assets:

```swift
let projection = SyncProjection(entity: "purchase", fields: ["quantity"])
let delta = try await store.zoneChanges(since: savedToken, projecting: [projection])
```

Fields left out of the projection decode as `nil` on the records the feed returns — **never
write a projected record back whole**, or you'll erase the fields you didn't fetch.
`SyncCoordinator(projecting:)` applies the same projections to every pass.

## 🔔 Push-triggered sync

One silent push per database change, then pull the delta — cheaper than a subscription per
entity:

```swift
try await store.subscribeToDatabase()
```

Wire the push handler to the coordinator:

```swift
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult
{
    _ = try? await coordinator.handlePush(userInfo)
    return .newData
}
```

`subscribe(entity:filters:id:)` creates a per-entity subscription instead, if you'd rather
filter server-side which changes wake the app; only server-evaluable filters are allowed
there.

## 🔴 Live queries in SwiftUI

`query(_:).live()` returns an observable model that re-runs the query whenever a local write
or an applied sync delta touches its entity — no manual refresh:

```swift
struct PurchaseListView: View {
    @State private var purchases = store.query(Purchase.self).live()

    var body: some View {
        List(purchases.items, id: \.productId) { Text($0.productId ?? "") }
    }
}
```

`purchases.items` updates on the main actor as new results arrive; `purchases.error` is set
(and tracking ends) if the underlying query throws. This is why `SyncCoordinator` passes are
worth running even when nothing in the UI is polling directly — a live query updates itself
the moment a coordinator pass lands.

Changes that land while a pass is running coalesce into the single pass that follows it, so a
loop of writes — or a delta that touches the entity many times — costs the pass in flight and
one that picks up everything the burst changed, not one full query per change. The view sees
the settled result instead of every step. `changeTicks(entity:)` is the uncoalesced stream
underneath, one tick per landed mutation, if you want to drive something else with it.

A mutation that names the records it changed — every write, update, delete, and unprojected
sync pass — is folded into the last result instead of re-read, so the stream costs the query
once and the changes after it. The fold re-tests each changed record against every filter, so
a record that stops matching leaves the result and one that starts matching joins it. Some
shapes still go back to the server: a `limit`, because a record leaving the top can admit one
the change never mentioned; a projection, an OR group, or a `createdBy` scope; a `near` filter
or a distance sort, which have no client-side equivalent; and any mutation that cannot name
what it touched, such as a compaction or a projected sync pass.

## ⚖️ Trade-offs

- Progress from a batched walk is a running count, not a fraction — the total size of an
  unfetched backlog isn't knowable in advance.
- A partial (projected) sync trims what's mirrored; combine it with a `ReplicaCache` built
  from the same projection (see [Offline](offline.md)) rather than assuming the trimmed
  records are safe to treat as complete.
