# Getting Started

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/kasianov-mikhail/scout-db.git", from: "0.1.0")
]
```

## Upload the schema

The physical CloudKit schema ships as the [`Schema`](../Schema) file at the repository root.
Upload it once per container:

```sh
xcrun cktool import-schema \
    --team-id <team> --container-id <container> \
    --environment development --file Schema
```

Deploy to Production from the CloudKit Console when ready. After that the file is frozen —
every schema change in your app is a data change, not a re-import.

## Connect

```swift
import CloudKit
import ScoutDB

let database = CKContainer(identifier: "iCloud.com.example.app").publicCloudDatabase
let registry = SchemaRegistry(database: database)
let store = UniversalStore(database: database, registry: registry)
```

## Declare an entity

```swift
try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("quantity", .int, .minimum(0))
    .field("amount", .double)
    .field("date", .timestamp)
    .field("comment", .string, .payload)
    .envelopeDate("date")
    .create()
```

The builder assigns slots automatically. Fields marked `.payload` skip slots — use it for
everything you never filter on.

## Write and query

```swift
try await store.write([
    "product_id": .string("sku-42"),
    "quantity": .int(3),
    "amount": .double(29.97),
    "date": .date(.now),
], entity: "purchase")

let recent = try await store.query("purchase")
    .filter("quantity" > 1)
    .sort("date", .descending)
    .limit(20)
    .all()
```

## Where to go next

- [Schema](schema.md) — the frozen physical schema and its budget
- [Migrations](migrations.md) — evolving entities without ever re-importing
- [Filtering](filtering.md) — the query builder and shadow-slot techniques
- [Operators](operators.md) — the full operator reference
- [Aggregation](aggregation.md) — materialized counters, sums, and percentiles
- [Security](security.md) — field encryption and trusted writers
