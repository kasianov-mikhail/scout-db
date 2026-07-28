# 📡 Sync

ScoutDB has no change feed: a device learns what other devices wrote by reading again. What
the library gives you is the wiring around that read — push notifications that say *when* to
read, and live queries that keep a SwiftUI view on the latest local state.

## 🔔 Push-triggered reads

One silent push per database change, cheaper than a subscription per entity:

```swift
try await store.subscribeToDatabase()
```

The push says only "something changed", so the handler re-reads what the screen cares about:

```swift
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult
{
    let fresh = try? await store.query(Purchase.self).limit(100).all()
    return fresh == nil ? .noData : .newData
}
```

`subscribe(entity:filters:id:)` creates a per-entity subscription instead, if you'd rather
filter server-side which changes wake the app; only server-evaluable filters are allowed
there.

## 📨 Reading a push without a follow-up fetch

A subscription made with `projecting:` puts the named fields into the notification payload,
and `record(fromPush:)` decodes them without going back to the server:

```swift
try await store.subscribe(entity: "purchase", projecting: ["quantity"])
// ...
let record = try await store.record(fromPush: userInfo)
```

Keep the projection light — the payload shares the notification's size budget — and treat the
fields it left out as `nil` rather than as cleared. `ChangeEvent(userInfo:)` is the raw
mapping underneath, when you want the kind and uuid without the record. A ScoutDB delete is a
tombstone rewrite, so it arrives as an update; `.deleted` only appears for hard deletes.

## 🔴 Live queries in SwiftUI

`query(_:).live()` returns an observable model that re-runs the query whenever a local write
touches its entity — no manual refresh:

```swift
struct PurchaseListView: View {
    @State private var purchases = store.query(Purchase.self).live()

    var body: some View {
        List(purchases.items, id: \.productId) { Text($0.productId ?? "") }
    }
}
```

`purchases.items` updates on the main actor as new results arrive; `purchases.error` is set
(and tracking ends) if the underlying query throws. Only mutations through this process's
stores tick the stream — a write made on another device shows up when something re-reads,
which is what the push handler above is for.

Changes that land while a pass is running coalesce into the single pass that follows it, so a
loop of writes costs the pass in flight and one that picks up everything the burst changed,
not one full query per change. The view sees the settled result instead of every step.
`changeTicks(entity:)` is the uncoalesced stream underneath, one tick per landed mutation, if
you want to drive something else with it.

A mutation that names the records it changed — every write, update, and delete — is folded
into the last result instead of re-read, so the stream costs the query once and the changes
after it. The fold re-tests each changed record against every filter, so a record that stops
matching leaves the result and one that starts matching joins it. Some shapes still go back to
the server: a `limit`, because a record leaving the top can admit one the change never
mentioned; a projection, an OR group, or a `createdBy` scope; a `near` filter or a distance
sort, which have no client-side equivalent; and any mutation that cannot name what it touched,
such as a compaction.

## ⚖️ Trade-offs

- Catching up costs a query, and its cost follows what the query returns rather than what
  changed. Narrow the read — filters, `limit`, projections — rather than re-reading whole
  entities on every push.
- Pushes are best-effort. Re-read when a scene comes to the foreground too, or a dropped
  notification leaves the screen stale until the next one arrives.
- A per-entity subscription can only be filtered by predicates the server evaluates;
  `like`, `matches`, `isNull` and payload fields are rejected rather than silently ignored.
