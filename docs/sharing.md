# 🔗 Sharing

CloudKit sharing works over the private database: a `CKShare` grants other iCloud users
access to a zone or a single record, and CloudKit routes their reads/writes into their own
`sharedDatabase`. ScoutDB wraps the operation pairs (create, invite, accept) that a share
otherwise takes several raw CloudKit calls to assemble.

## 🗂️ Zone-wide vs single-record

Share every record in the store's custom zone:

```swift
let share = try await store.shareZone(title: "Household")
```

Share one record instead, alongside (not instead of) any zone-wide share:

```swift
let share = try await store.shareRecord(entity: "purchase", uuid: "p-1", title: "Receipt")
```

Both calls are idempotent — call them again and you get the existing share back rather than
a duplicate. `shareRecord` fails with `SchemaError.notFound(uuid)` if the record doesn't
exist or belongs to a different entity; `shareZone`/`shareRecord` need a custom zone
(`EntityStore.zoneID`) and fail with `SchemaError.invalidDefinition` without one.

```swift
let existing = try await store.zoneShare()                       // nil if unshared
let existing = try await store.recordShare(entity: "purchase", uuid: "p-1")
try await store.stopSharing()                                    // zone-wide
try await store.stopSharing(entity: "purchase", uuid: "p-1")      // single record
```

`stopSharing` deletes the share record only — the underlying data stays.

## ✉️ Inviting participants

```swift
try await store.inviteToShare(
    emails: ["ada@example.com"],
    permission: .readWrite,
    via: container
)

try await store.inviteToShare(
    emails: ["ada@example.com"],
    permission: .readOnly,
    on: share,          // single-record share
    via: container
)
```

Open the share to anyone with the link instead of naming participants:

```swift
try await store.setSharePublicPermission(.readWrite)   // or .readOnly / .none
```

`removeShareParticipant(_:from:)` drops a participant; removing the owner throws
`SchemaError.invalidValue("owner")` instead of letting CloudKit raise an unrecoverable error.

## ✅ Accepting an invitation

The recipient gets a share URL (from Messages, Mail, or your own delivery). Turn it into a
share and read from it:

```swift
let metadata = try await container.acceptShare(at: url)

let sharedStore = EntityStore(
    database: container.sharedDatabase,
    registry: registry,
    zoneID: metadata.share.recordID.zoneID
)
```

`acceptShare(at:)` fetches the share's metadata and accepts it in one call; if the fetch
fails, nothing is accepted. Build the recipient's store against `sharedDatabase` and the zone
from the metadata — everything else (queries, filters, writes) works the same as against a
private zone.

## ⚠️ Limits

- Sharing needs a custom zone; the default zone cannot be shared.
- A single-record share requires its root record to already exist — create it before sharing.
- Participant permission changes and removals only apply to shares that already exist —
  share first, invite second.
