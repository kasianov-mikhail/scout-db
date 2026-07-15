# 📊 Aggregation

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

## 📐 Metrics

Every view counts writes (`COUNT`). One metric per view on top of that:

| Declaration | Maintains |
|---|---|
| `sum: "amount"` | running total; `average` derives at read time |
| `min:` / `max:` | the extremum |
| `stats: "amount"` | Σx and Σx² — `variance` and `standardDeviation` derive at read time |
| `histogram: .init(field:bounds:)` | value buckets for percentiles |

Buckets: `hour` (default), `weekday`, `day`.

## 📖 Reading

```swift
let rows = try await store.aggregate(entity: "payment", view: "revenue", from: june, to: july)
// [AggregateRow(group: "pro", period: ..., count: 48211, value: 481628.9), ...]

let top = try await store.totals(entity: "payment", view: "revenue") { $0.count >= 10 }
// GROUP BY group across the period range, HAVING via the closure

let p95 = try await store.percentile(0.95, entity: "payment", view: "latency")

let products = try await store.distinct(entity: "payment", field: "product")
```

`aggregate` returns one row per group and period; `totals` folds periods per group and
filters with the `having:` closure. `distinct` is a client-side scan — materialize a view
for large entities.

## ⚖️ Trade-offs

| | |
|---|---|
| 🔮 **Questions must be known in advance.** | A view added later covers new writes only; replay history through a backfill to cover the past. |
| ✍️ **Write amplification.** | Each view adds one counter update per write. |
| 🤝 **Concurrent writers merge.** | Aggregates update by compare-and-swap on the grid record's change tag, instead of overwriting each other. |
| 🔁 **Deletes and updates rebalance the views.** | `delete`, `deleteAll`, `reap`, `update`, and `updateAll` reverse the removed record's contribution, so `count`, `sum`, `stats`, and `histogram` views stay accurate as records change. A `min`/`max` extremum is the exception: it cannot be recomputed without rescanning, so its value is left as-is when a record leaves (the count still decrements). Backfill a `min`/`max` view if you need it exact after deletes. |
