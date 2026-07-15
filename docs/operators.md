# ⚙️ Operators

Query and aggregation operators ScoutDB supports. See the [README](../README.md) for
the architecture this builds on.

```swift
let filter = EntityStore.Filter(field: "title", op: .endsWith, value: .string("World"))
let notes = try await store.read(entity: "note", filters: [filter])
```

## 🔢 Comparison

| Operator | Notes |
|---|---|
| `equals` / `notEquals` | exact match |
| `greaterThan` / `lessThan` (+ `OrEquals`) | range comparison |
| `in` / `notIn` | list membership |
| `Filter.between(field, lower, upper)` | inclusive range |

## 🔤 String matching

| Operator | Notes |
|---|---|
| `beginsWith` | prefix match |
| `endsWith` | fastest with a `reversed` shadow field |
| `contains` | substring; a `ngrams` shadow field speeds it up |
| `like` (`*`, `?`) | wildcards, whole-string match |
| `matches` | regular expression, whole-string match |
| `search` | whole-token full-text on a `text` field |

Case/diacritic-insensitive matching and substring search are shadow-field techniques, not
operator flags — declare a derived `fold`, `reversed`, or `ngrams` field once and the matching
operators pick it up automatically.

## 🌍 Collections and geo

- `contains` on a list field — membership: `tags CONTAINS "swift"`
- `Filter.containsAll(field, values)` — every value present
- `Filter.containsAny(field, values)` — at least one present, via `read(any:)`
- `near` — radius match on a `location` field, in meters

## ❓ Existence

`isNull` / `isNotNull` — match records missing or carrying a value; work on payload fields too.

## 🔀 OR and ORDER BY

CloudKit only combines predicates with `AND`. `read(entity:any:)` emulates `OR` across branches;
prefer a single `in` filter when branches only differ by value.

`sort:` gives server-side `ORDER BY`.

## 📊 Aggregation

Declare `views` on the definition; every write updates counters so reads never scan raw records.

| Operator | Source |
|---|---|
| `COUNT`, `SUM`, `MIN`, `MAX` | declared on a view |
| `AVG`, `STDDEV`, `VARIANCE` | derived from view metrics at read time |
| Percentiles | from a histogram view |
| `GROUP BY` | `aggregate(...)` and `totals(...)` |
| `HAVING` | the `having:` closure of `totals(...)` |
| `DISTINCT` | `distinct(entity:field:)` |

## 🧵 Read and write shapes

| Feature | API |
|---|---|
| Projection | `read(entity:filters:fields:)` |
| Streaming | `stream(entity:filters:pageSize:)` |
| Query plan | `explain(entity:filters:sort:)` |
| Batch update | `updateAll(entity:filters:transform:)` |
| Batch delete | `deleteAll(entity:filters:)` |
| Transactions | `transaction { $0.write(...) }`, repaired by `repairTransactions(olderThan:)` |

## 🪄 Derived transforms

| Transform | Does | Used for |
|---|---|---|
| `lowercase` | lowercase | case-insensitive equality |
| `fold` | lowercase + strip diacritics | accent-insensitive matching |
| `reversed` | reverse the string | server-side `endsWith` |
| `ngrams` | trigrams of the folded value | substring / wildcard prefilter |
| `hour` / `day` / `week` / `month` | bucket a timestamp | time grouping |
| `hmac` | keyed hash | filterable surrogate for an encrypted field |

## 🚫 Not supported

- Fully server-side substring, wildcard, or regex matching — verification is always client-side.
- Single-query `OR` — it's a query per branch.
- Aggregation over raw records at read time — must be materialized via `views`.
