# Aggregates

ScoutDB keeps aggregates up to date on every write, so reading a count, a total or a series does
not scan the records.

## Groups and hours

An aggregate keeps one number per **group** and **hour**. A group is one value of the grouping
field, for example one `product_id`. An aggregate without a grouping field has a single group.

A count and a sum over the same grouping are two aggregates.

## Automatic counts

`create()` adds a count aggregate for every **groupable** field: a `.string`, `.reference`, `.int` or
`.double` field in a slot. Payload fields, list fields, `.text`, `.timestamp`, `.bytes` and `.asset`
fields are not groupable.

So after this declaration, `count()` filtered by `product_id` or `status` works with no extra code:

```swift
try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("status", .string)
    .field("order_id", .string, .ungrouped)
    .field("date", .timestamp)
    .create()
```

Mark a field `.ungrouped` when it has many distinct values that nobody counts by, such as an id or
free text. Each groupable field adds work to every write.

`update()` never adds automatic counts. See
[Schema evolution](schema-evolution.md#what-update-returns).

## Declaring aggregates

Declare everything else on the schema builder:

```swift
try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("amount", .double, .required)
    .field("date", .timestamp)
    .sum("amount", by: "product_id", at: "date")
    .min("amount", by: "product_id")
    .max("amount", by: "product_id")
    .create()
```

| Builder method | Keeps |
|-|-|
| `count(by:at:shards:parts:)` | The number of records per group. Use it for `.ungrouped` fields, for sharding, or for a count with no grouping. |
| `sum(_:by:at:shards:parts:)` | The running total of a numeric field per group. |
| `min(_:by:at:)` | The smallest value per group. |
| `max(_:by:at:)` | The largest value per group. |
| `histogram(of:bounds:at:)` | Bucket counts of a numeric field, for percentiles. |

Parameters:

- **`by`** — the grouping field. Omit it for one group over all records.
- **`at`** — a `.timestamp` field that dates the record. Without it, a record lands in the hour of
  the write. Set `at` when you read [series](#series).
- **`shards`** — `2...64`. Use it only when many devices write the same group at the same time.
- **`parts`** — `2...64`. Spreads the week's list of groups over several index records. Set it when
  the grouping field has thousands of values, such as a device id. An `update()` may raise it later;
  the pages written before stay readable.

`min` and `max` are running extremes. Deleting or rewriting the record that set the extreme does not
lower it: the aggregate answers with what the group once reached.

## Reading single values

These methods read one number for the records that match the builder's filters.

```swift
let paid = try await store.query("purchase").filter("status", .equals, "paid").count()
let revenue = try await store.query("purchase").filter("product_id", .equals, "sku-42").sum("amount")
let cheapest = try await store.query("purchase").min("amount")
let peak = try await store.query("purchase").max("amount")
let basket = try await store.query("purchase").average("amount")
```

| Method | Needs | Empty result |
|-|-|-|
| `count()` | a count aggregate covering the filter | `0` |
| `sum(_:)` | a `sum` aggregate of the field | `0` |
| `min(_:)`, `max(_:)` | a `min` or `max` aggregate of the field | `nil` |
| `average(_:)` | a `sum` of the field and a count, over the same grouping | `nil` |

`sum`, `min`, `max` and `average` need an `.int` or `.double` field. `average` also needs the field to
be `.required` or to carry a `.defaultValue`. The count divides by every record of the group, so a
record without the field would pull the mean down.

### Which filters an aggregate can serve

An aggregate read never falls back to reading records. If no declared aggregate covers the query, the
call throws and the error names the aggregate to declare. The filters an aggregate can serve are:

- no filter at all;
- an equality or an `.in` on the aggregate's grouping field, or `||` alternatives of them:

  ```swift
  try await store.query("purchase")
      .filter("product_id" == "sku-42" || "product_id" == "sku-7")
      .count()
  ```

### Count

`count()` also serves a range filter on an `.int` field that a count aggregate groups by, when the
field has both `.min` and `.max`.

```swift
try await store.schema("rating")
    .field("stars", .int, .required, .min(1), .max(5))
    .create()

let positive = try await store.query("rating").filter("stars" >= 4).count()
```

`count()` stops at the builder's [`limit`](queries.md#limits).

## Totals per group

`totals(_:metric:group:)` returns one `AggregateTotal` per group, folded over every hour the
aggregate holds.

```swift
let revenue = try await store.query("purchase")
    .totals("amount", metric: .sum, group: "product_id")
// [AggregateTotal(group: "sku-42", value: 481628.9), ...]

let orders = try await store.query("purchase")
    .totals(metric: .sum, group: "product_id")
// record counts per product
```

- Omit the field to read the count of records per group. The metric is then `.sum`.
- `metric` chooses which aggregate answers: `.sum`, `.min`, `.max` or `.average`. `.average` divides
  the `sum` aggregate by the count aggregate of the same grouping.
- The only filter allowed is an equality on the grouping field. Any other filter throws.
- `AggregateTotal` is `Comparable` by group, so `totals.sorted()` orders the rows by group.

## Series

`series(_:metric:group:in:)` returns one `SeriesPoint` per group and hour in a date range.

```swift
let now = Date.now
let lastWeek = now.addingTimeInterval(-7 * 24 * 3600)..<now

let hourly = try await store.query("purchase")
    .series("amount", metric: .sum, group: "product_id", in: lastWeek)
```

- An hour is the finest resolution. Roll the points up into days or weeks on the client.
- The series is sparse. An hour without writes has no point, not a zero point.
- `SeriesPoint` has `group`, `date` (the start of the hour) and `value`. It is `Comparable` by date,
  then group.
- `metric`, `group` and the allowed filters work as in `totals`.

## Percentiles

Declare a histogram with the upper bounds of its buckets, then read percentiles from it:

```swift
try await store.schema("request")
    .field("latency", .double, .ungrouped)
    .histogram(of: "latency", bounds: [10, 25, 50, 100, 250, 500, 1_000])
    .create()

let p95 = try await store.query("request").percentile(0.95, of: "latency")
```

- Bounds are exclusive upper bounds, ascending and distinct, 1 to 63 of them. `n` bounds make `n + 1`
  buckets; the last bucket takes every value at or above the last bound.
- The answer is interpolated inside its bucket, so its precision follows the bounds you choose.
- A percentile that falls in the first or the last bucket returns that bucket's bound.
- `rank` is in `0...1`. The result is `nil` when no record carries the field.
- A histogram has no grouping, and `percentile` does not accept filters.
- Mark the field `.ungrouped` unless you also want a count per distinct value.

## What aggregates cost

Aggregates move cost from reads to writes. Every write to an entity with aggregates also updates
them. Concurrent writes from many devices do not lose updates.

Declare the aggregates your screens read, and mark the other fields `.ungrouped`.

An aggregate can group by a field with many values, such as a device id. Give it `parts`, because
one index record cannot hold tens of thousands of groups for a week. A read fetches one record per
group and week, so its cost grows with the number of groups in the range.
