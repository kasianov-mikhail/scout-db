# 🚀 Getting Started

## 📦 Installation

```swift
dependencies: [
    .package(url: "https://github.com/kasianov-mikhail/scout-db.git", from: "0.2.0")
]
```

## 📤 Upload the schema

The physical CloudKit schema ships as the [`Schema`](../Schema) file at the repository root.
Upload it once per container through the CloudKit Console: select your container, open
**Schema**, and use **Import Schema** to upload the file to the Development environment.

Deploy to Production from the CloudKit Console when ready. After that the file is frozen —
every schema change in your app is a data change, not a re-import.

## 🔌 Connect

```swift
import CloudKit
import ScoutDB

let database = CKContainer(identifier: "iCloud.com.example.app").publicCloudDatabase
let registry = SchemaRegistry(database: database)
let store = EntityStore(database: database, registry: registry)
```

## 🧱 Declare an entity

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

Fields marked `.payload` skip server-side filtering — use it for everything you never filter on.

## ✍️ Write and query

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

## 🧭 Where to go next

| Doc | Covers |
|---|---|
| 🧬 [Schema](schema.md) | the frozen physical schema |
| 🔄 [Migrations](migrations.md) | evolving entities without ever re-importing |
| 🔍 [Filtering](filtering.md) | the query builder and shadow-field techniques |
| ⚙️ [Operators](operators.md) | the full operator reference |
| 📊 [Aggregation](aggregation.md) | materialized counters, sums, and percentiles |
| 📎 [Records](records.md) | assets, relations, revisions, soft delete, and TTL |
| 🧩 [The @Entity macro](macros.md) | typed structs instead of value dictionaries |
| 🔗 [Sharing](sharing.md) | zone-wide and single-record `CKShare`s |
| 📡 [Sync](sync.md) | the zone change feed, selective sync, and live queries |
| 📴 [Offline](offline.md) | zone replicas and the queued write cache |
| 🔐 [Security](security.md) | field encryption and trusted writers |
| 📈 [Telemetry](telemetry.md) | request observability and previously-silent failures |
