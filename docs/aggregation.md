# Aggregation

CloudKit has no server-side `SUM` or `GROUP BY` — a query returns records, never computed
values. ScoutDB materializes aggregates at write time instead: every write updates counters
in `Aggregate` cells, so reads never scan raw records.

`create()` builds that grid on its own. Every groupable field — a scalar string, reference,
int or double in a slot — gets a `lifetime` view named `by_<field>` counting its values, and
an entity with an `envelopeDate` gets a `by_day` view counting its records:

```swift
try await store.schema("payment")
    .field("product", .string)
    .field("amount", .double)
    .field("date", .timestamp)
    .envelopeDate("date")
    .create()

let products = try await store.query("payment").totals(by: "product")
let counted = try await store.query("payment").filter("product", .equals, "pro").count()
```

So `count`, `count(by:)` and `distinct` are answered from the grid without anyone declaring
anything. What stays to be declared is what nobody can infer — a metric, a histogram, a
coarser bucket — and a declaration supersedes the plain count the grid would have built over
the same grouping:

```swift
try await store.schema("payment")
    .field("product", .string)
    .field("amount", .double)
    .field("date", .timestamp)
    .field("receipt_id", .string, .ungrouped)   // many distinct values, nothing counts by it
    .envelopeDate("date")
    .sum("amount", by: "product", bucket: .hour)
    .histogram(of: "amount", bounds: [10, 50, 100])
    .create()
```

| Declaration | Maintains |
|---|---|
| `count(by:bucket:)` | a counter per group and period |
| `sum(_:by:)` | running total; `average` derives at read time |
| `min(_:by:exact:)` / `max(...)` | the extremum |
| `stats(_:by:)` | Σx and Σx² — `variance` and `standardDeviation` derive at read time |
| `histogram(of:bounds:)` | value buckets for percentiles |
| `.ungrouped` on a field | keeps it out of the grid entirely |

One grid record covers one group and period; a million writes still read back as a handful
of grid records.

On an `update()` a declared aggregate joins the entity's existing ones instead of replacing
them, so giving one field a metric leaves the rest of the grid standing. An aggregate lapses
only with the field it is kept over: close the field, and its cells stop being written. They
stay in the database untouched, so declaring the same shape again calls for a
`Migrator.backfill(view:entity:)` pass before it can be trusted.

The grid costs the writes it saves the reads. An entity carrying one reads its records before
it rewrites them and rewrites its cells after: three requests per write batch on top of the
save, plus a retry round per cell that loses a compare-and-swap. Declaring a view over a field
of many distinct values — a uuid, a reference, a free-form string — buys one grid record per
value, so keep those for the fields a read actually groups by.

`update()` inherits whatever `create()` published and never builds a grid of its own; it
returns the names of the fields it added that nothing counts by, so a field gridded later is
one you declared and backfilled deliberately. Entities published before the grid
existed keep the views they were published with; `Migrator.backfill(view:entity:)` fills a
view's cells from the records already stored.

Those records are bookkeeping, not entity data, but they still cost a read. Cache the rows
in your app if you read them on a hot path.

## Table of Contents
- [Metrics](#metrics)
- [Reading](#reading)

## Metrics

Every aggregate counts writes (`COUNT`), with at most one metric on top of that. Buckets: `hour` (default), `weekday`, `day`, and `lifetime` — one running total per group with
no time grid, the only bucket that works without an `envelopeDate`.

## Reading

```swift
let top = try await store.query("payment").totals("amount", by: "product", from: june, to: july)
// [AggregateTotal(group: "pro", count: 48211, value: 481628.9), ...]

let p95 = try await store.query("payment").percentile(0.95, of: "amount")

let points = try await store.query("payment").series("amount", by: "product", from: june, to: july)
// [AggregateSeriesPoint(group: "pro", date: ..., count: 812, value: 8120.5), ...]

let apps = try await store.query("payment").filter("product", .equals, "app").totals("amount", by: "product")
// an equality filter on the grouping field narrows to that group, server-side

let products = try await store.query("payment").distinct("product")
```

A read names the grouping and the metric it wants, never a view: the grid answering that
shape is found by what it keeps. Left without a `bucket:` the finest grid over the grouping
wins, and a filter the grid cannot honor throws rather than being quietly dropped.

`totals` folds the whole range into one row per group — `count`, the metric's `value`, and
the `average`, `variance` and `standardDeviation` derived from them. `series` reads the same
grid one cell at a time instead: a point per non-empty cell, dated at the cell's own
position, which is the resolution a chart wants. `distinct` reads the grid of a view grouped by the field when one covers the query
(a `lifetime` view covers the unfiltered call) and the field is required or defaulted — one
grid row per live value, no record scan. Without a covering view it falls back to a
client-side scan — materialize a view for large entities.
