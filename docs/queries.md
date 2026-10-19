# Queries

`store.query(_:)` opens a chainable `QueryBuilder`. The builder is a value: nothing runs until a
terminal method asks for results, so you can store a builder, pass it around and reuse it.

```swift
let recent = try await store.query("purchase")
    .filter("quantity" > 1)
    .filter("product_id", .equals, "sku-42")
    .sort("date", .reverse)
    .take(20)
```

## Terminal methods

| Method | Returns |
|-|-|
| `take(_:)` | At most `count` matching records. |
| `first()` | The first matching record in sort order, or `nil`. |
| `page(size:after:)` | One keyset page and a cursor to the next one. |
| `count()`, `sum(_:)`, `min(_:)`, `max(_:)`, `average(_:)` | A number read from an aggregate. See [Aggregates](aggregates.md). |
| `totals(_:metric:group:)`, `series(_:metric:group:in:)`, `percentile(_:of:)` | Aggregate reads. See [Aggregates](aggregates.md). |

`take(_:)` stops following the query cursor as soon as it has enough records, so its cost follows
what it returns, not the size of the entity. To read further, use `page(size:after:)`.

## Filters

`filter(_:)` takes an expression built with operators. Each call is combined with the previous ones
by `AND`.

```swift
try await store.query("purchase")
    .filter("quantity" >= 2 && "quantity" < 10)
    .filter("amount" > 100.0)
    .take(50)
```

`filter(_:_:_:)` spells a filter field by field. Use it for operators that have no symbol:

```swift
try await store.query("place")
    .filter("name", .beginsWith, "Cafe")
    .filter("category", .in, .strings(["coffee", "tea"]))
    .take(20)
```

### String equality

Inside `filter(_:)`, `"product_id" == "sku-42"` is a filter. Outside it, two string literals compared
with `==` resolve to Swift's own `String == String` and give a `Bool`. Annotate the type when you
build an expression ahead of time:

```swift
let isPaid: FilterExpression = "status" == "paid"

try await store.query("purchase")
    .filter(isPaid && "amount" > 100.0)
    .take(50)
```

### Operators

| Symbol | `Operator` | Matches records whose field… |
|-|-|-|
| `==` | `.equals` | equals the value. |
| `!=` | `.notEquals` | holds a value other than this one. A record without the field does not match. |
| `>`, `>=`, `<`, `<=` | `.greaterThan`, `.greaterThanOrEquals`, `.lessThan`, `.lessThanOrEquals` | compares to the value. |
| `=~` | `.beginsWith` | starts with the string. |
| `~~` | `.contains` | on a `.stringList`: contains the element. On a `.string`: contains the substring (checked on the client). |
| | `.in` | equals one of the listed values. |
| | `.notIn` | equals none of the listed values. |
| | `.search` | contains all the words of the value. `.text` fields in a slot only. |

```swift
try await store.query("post")
    .filter("tags" ~~ "swift")
    .filter("body", .search, "concurrency actors")
    .take(20)
```

### Server and client

A filter on a field in a slot runs on the CloudKit server. A filter on a
[payload field](schema.md#slots-and-payload-fields), and a substring `~~` on a `.string` field, run
on the client after decoding. Client filters are correct but not free: the server still returns every
record that the other filters match. Keep at least one server filter on large entities.

A filter on an `.asset` field throws.

### Disjunctions

CloudKit joins predicates only with `AND`. ScoutDB supports `||` by running one server query per
alternative and merging the results.

```swift
try await store.query("log")
    .filter("level" == "error" || ("level" == "warning" && "count" > 10))
    .take(50)
```

The cost is one request per alternative:

- `a || b` is two alternatives.
- `(a || b) && (c || d)` multiplies out to four alternatives.
- Equalities over the **same** field fold into one `in` filter, so
  `"level" == "error" || "level" == "fatal"` costs one request.

## Sorting

`sort(_:_:)` orders results by a field. The order is `.forward` by default; pass `.reverse` for
descending order. Later clauses break the ties of earlier ones.

```swift
try await store.query("purchase")
    .sort("date", .reverse)
    .sort("quantity")
    .take(20)
```

Sorting runs on the server, so the field must be in a slot and its type must be sortable: `.string`,
`.text`, `.int`, `.double` or `.timestamp`. Payload fields cannot be sorted.

## Limits

`limit(_:)` caps every terminal of the builder. When both are set, the smaller of `limit` and `take`
wins. `count()` also stops at the limit.

```swift
let base = store.query("purchase").sort("date", .reverse).limit(10)

let newest = try await base.take(50)   // 10 records
```

## Pagination

`page(size:after:)` returns a keyset page and a cursor. Pass the cursor back to get the next page;
the cursor is `nil` on the last page.

```swift
let query = store.query("purchase").sort("amount")

var page = try await query.page(size: 50)
process(page.records)

while let cursor = page.cursor {
    page = try await query.page(size: 50, after: cursor)
    process(page.records)
}
```

Requirements:

- exactly one `sort` clause;
- the sorted field is a scalar in a slot.

Disjunctions are allowed. A `FieldCursor` is `Codable`, so you can store it and continue later.

## Index lag

CloudKit indexes a write asynchronously. A query can miss a record for a short time after it is
written. When you need a record you just wrote, read it with
[`fetch(uuid:)`](records.md#fetching-by-uuid).
