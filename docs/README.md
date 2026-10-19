# ScoutDB documentation

ScoutDB adds entities, schema versions, structured queries and write-time aggregates on top of the
CloudKit public database. These guides cover the public API of the `ScoutDB` and `ScoutDBTesting`
libraries.

| Guide | What it covers |
|-|-|
| [Getting started](getting-started.md) | Installing the package, uploading the CloudKit schema, connecting a store, checking the iCloud account. |
| [Schema](schema.md) | Entities, field types, constraints, payload fields and slot limits. |
| [Schema evolution](schema-evolution.md) | Publishing new versions, what `update()` does to each field, and migrations. |
| [Records](records.md) | Writing, upserting and fetching records, `RecordValue`, typed access, lists and assets. |
| [Queries](queries.md) | Filters, operators, disjunctions, sorting, limits and keyset pagination. |
| [Aggregates](aggregates.md) | Counts, sums, extremes, averages, totals per group, hourly series and percentiles. |
| [Testing](testing.md) | `InMemoryDatabase`, `InMemoryContainer`, request budgets and fault injection. |

## The model in one page

- **Entity.** A named record type, such as `purchase`. Every entity shares one physical CloudKit
  record type, so a new entity or field never needs a schema upload.
- **Field.** A name, a [type](schema.md#field-types) and optional
  [constraints](schema.md#constraints). A field lives in a *slot*, a typed column the server can
  filter and sort on, or in a *payload* slot that only the client reads.
- **Version.** Every `create()` or `update()` publishes a version of the entity. A record keeps the
  version it was written under and decodes through it forever.
- **Aggregate.** A counter, sum, minimum, maximum or histogram that a write folds into hourly cells.
  Reads of aggregates cost a few records, however large the entity grows.

```swift
import CloudKit
import ScoutDB

let database = CKContainer(identifier: "iCloud.com.example.app").publicCloudDatabase
let store = EntityStore(database: database, registry: SchemaRegistry(database: database))

try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("amount", .double, .required)
    .field("date", .timestamp)
    .sum("amount", by: "product_id", at: "date")
    .create()

try await store.write(
    [EntityWrite(values: ["product_id": "sku-42", "amount": 9.99, "date": .date(.now)], uuid: nil)],
    entity: "purchase"
)

let latest = try await store.query("purchase")
    .filter("product_id", .equals, "sku-42")
    .sort("date", .reverse)
    .take(20)

let revenue = try await store.query("purchase")
    .totals("amount", metric: .sum, group: "product_id")
```
