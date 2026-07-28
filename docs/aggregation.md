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

Those records are bookkeeping, not entity data, but they still cost a read. Cache the rows
in your app if you read them on a hot path.

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
filters with the `having:` closure. `distinct` reads the grid of a view grouped by the
field when one covers the query (a `lifetime` view covers the unfiltered call) and the
field is required or defaulted — one grid row per live value, no record scan. Without a
covering view it falls back to a client-side scan — materialize a view for large entities.

## ⚖️ Trade-offs

<table>
<colgroup>
<col width="38%">
<col width="62%">
</colgroup>
<tbody>
<tr>
<td>🔮 <strong>Questions must be known in advance.</strong></td>
<td>A view added later covers new writes only; replay history through a backfill to cover the past.</td>
</tr>
<tr>
<td>✍️ <strong>Write amplification.</strong></td>
<td>Each view adds one counter update per write.</td>
</tr>
<tr>
<td>🤝 <strong>Concurrent writers merge.</strong></td>
<td>Aggregates update by compare-and-swap on the grid record's change tag, instead of overwriting each other.</td>
</tr>
<tr>
<td>🎯 <strong>An extremum can be kept exact.</strong></td>
<td>Declare <code>exact: true</code> on a <code>min</code>/<code>max</code> view and a removal that takes the standing extremum out recomputes that cell from the records behind it, instead of leaving the value it saw. The recompute reads one cell — an hour, a day or a week of one group — so a <code>lifetime</code> bucket rereads the group whole. Not available alongside <code>shards</code>, whose slices no query can name, or when the view groups by a payload or encrypted field, which no filter can narrow by.</td>
</tr>
<tr>
<td>🔁 <strong>Deletes and updates rebalance the views.</strong></td>
<td><code>delete</code>, <code>deleteAll</code>, <code>reap</code>, <code>update</code>, and <code>updateAll</code> reverse the removed record's contribution, so <code>count</code>, <code>sum</code>, <code>stats</code>, and <code>histogram</code> views stay accurate as records change. A <code>min</code>/<code>max</code> extremum is the exception: it cannot be un-applied, so its value is left as-is when a record leaves (the count still decrements) unless the view declares <code>exact</code>. Backfilling a <code>min</code>/<code>max</code> view also restores it.</td>
</tr>
</tbody>
</table>
