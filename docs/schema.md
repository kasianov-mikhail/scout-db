# Schema

An entity is declared in code with a chainable `SchemaBuilder`. Nothing reaches the database until
`create()` or `update()` publishes the declaration.

```swift
try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("quantity", .int, .min(1), .max(20))
    .field("amount", .double)
    .field("status", .string, .allowed(["placed", "paid", "refunded"]), .defaultValue("placed"))
    .field("date", .timestamp)
    .field("comment", .string, .payload)
    .create()
```

`create()` publishes version 1. Later changes go through `update()`; see
[Schema evolution](schema-evolution.md).

## Entity names

Any string works as an entity name, except names that start with `__`.

## Field types

Each field type maps to one `RecordValue` case. A write must carry the matching case.

| `FieldType` | `RecordValue` case | Swift type | Slots | Sortable |
|-|-|-|-|-|
| `.string` | `.string` | `String` | 30 | yes |
| `.text` | `.string` | `String` | 16 | yes |
| `.int` | `.int` | `Int`, `Int64`, `Bool` literal | 31 | yes |
| `.double` | `.double` | `Double` | 32 | yes |
| `.timestamp` | `.date` | `Date` | 32 | yes |
| `.bytes` | `.bytes` | `Data` | 16 | no |
| `.reference` | `.reference` | uuid `String` | 16 | no |
| `.asset` | `.asset` | `Asset` | 4 | no |
| `.stringList` | `.strings` | `[String]` | 8 | no |
| `.intList` | `.ints` | `[Int]`, `[Int64]` | 8 | no |
| `.doubleList` | `.doubles` | `[Double]` | 8 | no |
| `.timestampList` | `.dates` | `[Date]` | 8 | no |
| `.referenceList` | `.references` | `[String]` of uuids | 8 | no |
| `.bytesList` | `.blobs` | `[Data]` | 8 | no |

Notes:

- **`.string` and `.text`.** Both hold a `String`. Only a `.text` field supports the full-text
  `.search` operator; see [Queries](queries.md#operators).
- **Booleans.** There is no boolean type. Store a flag in an `.int` field; the literals `true` and
  `false` become `1` and `0`.
- **Dates.** A `.timestamp` keeps millisecond precision.
- **`.asset`.** Use it for files; see [Records](records.md#bytes-and-assets). No query can filter
  on an asset field.
- **`.reference`.** The value is the uuid of another record.

## Slots and payload fields

Each field takes a *slot* from the pool of its type. The "Slots" column above is the size of each
pool, that is, how many fields of that type one entity can hold. Queries filter and sort on a field
in a slot.

A field marked `.payload` takes one of **16 payload slots** instead. Use it for values you never
filter or sort on, such as comments, notes or raw JSON:

- It spends no typed slot.
- A filter over it runs on the device, after the other filters; see
  [Queries](queries.md#server-and-client).
- It cannot be sorted on and cannot carry a page cursor.

A slot stays taken after its field is closed or retyped; see
[Schema evolution](schema-evolution.md#slots-across-versions). Plan for the pool, not only for the
current version.

## Constraints

Constraints are checked on the device before a write leaves it. A rejected write costs no request.

| Constraint | Applies to | Meaning |
|-|-|-|
| `.required` | any type | A write must carry the field, after the default is applied. |
| `.defaultValue(RecordValue)` | any type | The value a write gets when it omits the field. |
| `.allowed([String])` | `.string`, `.text`, `.stringList` | Every value must come from this closed set. |
| `.matches(String)` | `.string`, `.text`, `.stringList` | Every value must match this regular expression as a whole. |
| `.min(Double)` | `.int`, `.double`, `.intList`, `.doubleList` | Inclusive lower bound. |
| `.max(Double)` | `.int`, `.double`, `.intList`, `.doubleList` | Inclusive upper bound. |
| `.payload` | any type | Store the field in a payload slot; see above. |
| `.ungrouped` | any type | Do not build a count aggregate for this field; see [Aggregates](aggregates.md#automatic-counts). |

One field can carry several constraints:

```swift
.field("status", .string, .required, .allowed(["placed", "paid"]))
.field("quantity", .int, .min(1), .max(20))
.field("sku", .string, .matches("sku-[0-9]+"))
```

`.min` and `.max` describe every record of the entity, not only the next write. A count can use them
as the whole domain of an integer field; see [Aggregates](aggregates.md#count). For that reason a
later version may widen or drop the bounds but never narrow them.

## Aggregate declarations

The builder also declares aggregates: `count(by:at:shards:parts:)`, `sum(_:by:at:shards:parts:)`,
`min(_:by:at:)`, `max(_:by:at:)` and `histogram(of:bounds:at:)`. They are covered in
[Aggregates](aggregates.md#declaring-aggregates).

## Reading a schema back

`SchemaRegistry` returns the active fields of an entity, their rules, and the aggregates it keeps.

```swift
let schema = try await registry.schema(for: "purchase")

for field in schema.fields {
    print(field.name, field.type, field.required, field.payload)
}

for aggregate in schema.aggregates {
    print(aggregate.group, aggregate.date, aggregate.field, aggregate.metric, aggregate.parts)
}
```

An `update()` always publishes a new version. Compare both `fields` and `aggregates` with your
declaration before you call it, because an aggregate can change while the fields stay the same.

`publishedSchema(for:)` returns `nil` when nothing is published under the name. Use it to choose
between `create()` and `update()`. Any other failure, such as a network error, still throws:

```swift
if try await registry.publishedSchema(for: "purchase") == nil {
    try await store.schema("purchase")
        .field("product_id", .string, .required)
        .create()
}
```

## Validation errors

`create()` and `update()` validate the whole definition before they publish it. They throw when:

- the entity name starts with `__`;
- a pool runs out of slots, or the 16 payload slots run out;
- a constraint does not apply to the field type, or a pattern is not a valid regular expression;
- an update narrows the `.min` or `.max` of a kept field;
- an aggregate names an unknown field, dates its records by a field that is not a `.timestamp`, or
  folds a field that is not numeric;
- two aggregates have the same shape, or the `shards`, `parts` or histogram bounds are out of range.

The error's `localizedDescription` names the field or aggregate and the rule it broke.
