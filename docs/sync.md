# Sync

ScoutDB has no change feed: a device learns what other devices wrote by reading again. What
the library gives you is the wiring around that read — push notifications that say *when* to
read.

## Table of Contents
- [Push-triggered reads](#push-triggered-reads)
- [Reading a push without a follow-up fetch](#reading-a-push-without-a-follow-up-fetch)

## Push-triggered reads

A silent push per entity, narrowed server-side to the changes worth waking the app for:

```swift
try await store.query("purchase").subscribe()
try await store.query("order").filter("status" == "paid").subscribe()
```

Only filters the server can evaluate may narrow a subscription — `like`, `matches`, `isNull`
and payload fields are rejected rather than silently ignored. Subscribe once per entity the
screen depends on; saving under an existing `id:` replaces that subscription, and
`unsubscribe(id:)` and `subscriptions()` manage what is registered. The push then tells the
handler what to re-read:

```swift
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult
{
    guard let event = ChangeEvent(userInfo: userInfo) else { return .noData }
    let fresh = try? await store.query(Purchase.self).take(100)
    return fresh == nil ? .noData : .newData
}
```

## Reading a push without a follow-up fetch

A subscription made with `projecting:` puts the named fields into the notification payload,
and `record(fromPush:)` decodes them without going back to the server:

```swift
try await store.query("purchase").subscribe(projecting: ["quantity"])
// ...
let record = try await store.record(fromPush: userInfo)
```

Keep the projection light — the payload shares the notification's size budget — and treat the
fields it left out as `nil` rather than as cleared. `ChangeEvent(userInfo:)` is the raw
mapping underneath, when you want the kind and uuid without the record. A ScoutDB delete is a
tombstone rewrite, so it arrives as an update; `.deleted` only appears for hard deletes.
