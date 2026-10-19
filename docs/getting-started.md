# Getting started

## Requirements

- iOS 16.0+ or macOS 13.0+
- Swift 6.0+
- An [Apple Developer](https://developer.apple.com) account with CloudKit enabled for the app

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/kasianov-mikhail/scout-db.git", from: "0.2.0")
]
```

Add the `ScoutDB` product to the app target. Add `ScoutDBTesting` to the test target only; see
[Testing](testing.md).

## Upload the CloudKit schema

ScoutDB needs the record types declared in the [`Schema`](../Schema) file at the repository root.
Upload it once per container:

1. Open the [CloudKit Console](https://icloud.developer.apple.com/dashboard/) and select the container.
2. Open **Schema** and choose **Import Schema**.
3. Upload the file to the Development environment.
4. Deploy the schema to Production when the app is ready.

New entities, new fields and new versions never need a new upload.

## Connect a store

ScoutDB works with the **public** database only.

```swift
import CloudKit
import ScoutDB

let container = CKContainer(identifier: "iCloud.com.example.app")
let database = container.publicDatabase

let registry = SchemaRegistry(database: database)
let store = EntityStore(database: database, registry: registry)
```

- `SchemaRegistry` loads and caches entity definitions. Create one per database and share it.
- `EntityStore` is a small value. Pass it around freely; every store over the same registry sees the
  same schemas.
- Both take any `CloudDatabase`. `CKDatabase` conforms out of the box, and `ScoutDBTesting` ships an
  in-memory implementation.

## Check the iCloud account

Every CloudKit call fails when no iCloud account is signed in. Check the account before the first
store operation:

```swift
let status = try await container.accountStatus()

switch status {
case .available:
    break
case .noAccount:
    // Ask the user to sign in to iCloud.
    break
default:
    // .restricted is a device policy; .couldNotDetermine and
    // .temporarilyUnavailable are worth retrying later.
    break
}
```

`requireAccount()` does the same check and throws when the status is anything but `.available`.

The status can change during a session. CloudKit posts `CKAccountChangedNotification` when the user
signs out or switches accounts; check again after it.

## Next steps

- Declare entities in [Schema](schema.md).
- Write and read records in [Records](records.md) and [Queries](queries.md).
- Read totals and series in [Aggregates](aggregates.md).
