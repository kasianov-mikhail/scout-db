# Aggregation

CloudKit has no server-side `SUM` or `GROUP BY` — a query returns records, never computed
values. ScoutDB materializes aggregates at write time instead: declare `views` on an entity,
and every write updates counters in `Aggregate` cells, so reads never scan raw records.

```swift
try await store.schema("payment")
    .field("product", .string)
    .field("amount", .double)
    .field("date", .timestamp)
    .envelopeDate("date")
    .view(AggregateView(name: "revenue", groupBy: "product", bucket: .hour, sum: "amount"))
    .view(AggregateView(name: "latency", histogram: .init(field: "amount", bounds: [10, 50, 100])))
    .create()
```

One grid record covers one group and period; a million writes still read back as a handful
of grid records.

Those records are bookkeeping, not entity data, but they still cost a read. Cache the rows
in your app if you read them on a hot path.

## Table of Contents
- [Metrics](#metrics)
- [Reading](#reading)

## Metrics

Every view counts writes (`COUNT`). One metric per view on top of that:

| Declaration | Maintains |
|---|---|
| `sum: "amount"` | running total; `average` derives at read time |
| `min:` / `max:` | the extremum |
| `stats: "amount"` | Σx and Σx² — `variance` and `standardDeviation` derive at read time |
| `histogram: .init(field:bounds:)` | value buckets for percentiles |

Buckets: `hour` (default), `weekday`, `day`, and `lifetime` — one running total per group with
no time grid, the only bucket that works without an `envelopeDate`.

## Reading

```swift
let rows = try await store.aggregate(entity: "payment", view: "revenue", from: june, to: july)
// [AggregateRow(group: "pro", period: ..., count: 48211, value: 481628.9), ...]

let top = try await store.totals(entity: "payment", view: "revenue") { $0.count >= 10 }
// GROUP BY group across the period range, HAVING via the closure

let p95 = try await store.percentile(0.95, entity: "payment", view: "latency")

let points = try await store.series(entity: "payment", view: "revenue", from: june, to: july)
// [AggregateSeriesPoint(group: "pro", date: ..., count: 812, value: 8120.5), ...]

let products = try await store.distinct(entity: "payment", field: "product")
```

`aggregate` returns one row per group and period; `series` reads the same grid one cell at a
time instead — a point per non-empty cell, dated at the cell's own position, which is the
resolution a chart wants; `totals` folds periods per group and filters with the `having:`
closure. `distinct` reads the grid of a view grouped by the field when one covers the query
(a `lifetime` view covers the unfiltered call) and the field is required or defaulted — one
grid row per live value, no record scan. Without a covering view it falls back to a
client-side scan — materialize a view for large entities.
