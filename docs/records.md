# Records

## Writing

`write(_:entity:)` saves a batch of records and returns the uuid of each record it stored.

```swift
let uuids = try await store.write(
    [
        EntityWrite(
            values: [
                "product_id": "sku-42",
                "quantity": 3,
                "amount": 29.97,
                "date": .date(.now),
            ],
            uuid: nil
        )
    ],
    entity: "purchase"
)
```

- **New records.** An `EntityWrite` with `uuid: nil` gets a fresh uuid.
- **Upserts.** An `EntityWrite` with a uuid replaces the record stored under it, or creates it.
- **Duplicates in one batch.** Entries with the same uuid describe one record. The last one wins, so
  the result has one uuid per record, not one per entry.
- **Validation.** Types and [constraints](schema.md#constraints) are checked on the device before
  anything is sent. Unknown fields, type mismatches and missing required fields throw.
- **Aggregates.** If the entity has aggregates, the write also updates them. See
  [Aggregates](aggregates.md#what-aggregates-cost).

A uuid must be unique across the whole database, not only within its entity. Use ASCII letters,
digits, `-`, `_` and `.`, and do not start it with `_`.

## Fetching by uuid

```swift
let one = try await store.fetch(uuid: uuid)

let several = try await store.fetch(entity: "purchase", uuids: uuids)
```

- `fetch(uuid:)` resolves the entity from the record and returns `nil` when nothing is stored under
  the uuid.
- `fetch(entity:uuids:)` skips missing uuids and records of other entities, and returns the rest
  sorted by uuid.

To find records by their values, use [queries](queries.md).

## EntityRecord

Every read returns `EntityRecord` values.

| Property | Meaning |
|-|-|
| `entity` | The entity the record belongs to. |
| `uuid` | The record's identifier, stable across rewrites. |
| `schemaVersion` | The version the record was written under. |
| `values` | The fields, keyed by name, as `RecordValue`. |

Read fields through the typed subscript. It returns `nil` when the field is absent or holds another
type:

```swift
let record = try await store.query("purchase").sort("date", .reverse).first()

let product: String? = record?["product_id"]
let quantity: Int? = record?["quantity"]
let date: Date? = record?["date"]
```

The subscript also writes, which makes a read-modify-write short:

```swift
if var record = try await store.fetch(uuid: uuid) {
    record["status"] = "paid"
    try await store.write([EntityWrite(values: record.values, uuid: record.uuid)], entity: record.entity)
}
```

## RecordValue

`RecordValue` is an enum with one case per [field type](schema.md#field-types). Literals convert
directly, so most values need no case name:

```swift
let values: [String: RecordValue] = [
    "product_id": "sku-42",          // .string
    "quantity": 3,                   // .int
    "amount": 29.97,                 // .double
    "paid": true,                    // .int(1)
    "date": .date(.now),
    "tags": .strings(["gift", "sale"]),
    "receipt": .asset(pdfData),
]
```

Any `RecordValue.Convertible` type produces its value through `recordValue`. The library conforms
`String`, `Int`, `Int64`, `Double`, `Date`, `Data`, `Asset` and arrays of the list element types:

```swift
let values: [String: RecordValue] = [
    "date": Date.now.recordValue,
    "scores": [10, 20, 30].recordValue,  // .ints
]
```

`RecordValue` is `Codable` and `Hashable`, and `EntityRecord` is `Codable`, so records can be cached
or sent over the wire as they are.

## Lists

List fields hold arrays of one element type. Read them with the typed subscript:

```swift
let tags: [String]? = record["tags"]
let scores: [Int]? = record["scores"]
```

A `.stringList` field supports server-side membership tests with `~~`; see
[Queries](queries.md#operators).

## Bytes and assets

`.bytes` and `.asset` both carry `Data`. Use `.bytes` for small blobs and `.asset` for files.

The typed subscript keeps them apart. `Data` reads and writes `.bytes`; `Asset` reads and writes
`.asset`:

```swift
record["thumbnail"] = Data(thumbnailBytes)       // .bytes field
record["receipt"] = Asset(data: pdfData)         // .asset field

let receipt: Asset? = record["receipt"]
let pdf = receipt?.data
```

No query can filter on an asset field.
