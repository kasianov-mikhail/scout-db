# Operators

Query and aggregation operators ScoutDB supports. See the [README](../README.md) for
the architecture this builds on.

```swift
let filter = UniversalStore.Filter(field: "title", op: .endsWith, value: .string("World"))
let notes = try await store.read(entity: "note", filters: [filter])
```

Filters marked **server** run as CloudKit predicates. Filters marked **client** are checked
after decoding — pair them with at least one server filter on large entities.

## Comparison

| Operator | Side |
|---|---|
| `equals` / `notEquals` | server |
| `greaterThan` / `lessThan` (+ `OrEquals`) | server |
| `in` / `notIn` | server |
| `Filter.between(field, lower, upper)` | server |

## String matching

| Operator | Side | Notes |
|---|---|---|
| `beginsWith` | server | prefix match |
| `endsWith` | server* | *needs a `reversed` shadow field, else client |
| `contains` | server + client | substring, narrowed server-side via a shadow field |
| `like` (`*`, `?`) | server + client | wildcards, same narrowing |
| `matches` | client | regex, whole-string |
| `search` | server | whole-token full-text on a `text` field |

Case/diacritic-insensitive matching and substring search are shadow-field techniques, not
operator flags — declare a derived `fold`, `reversed`, or `ngrams` field once and the matching
operators pick it up automatically.

## Collections and geo

| Operator | Side |
|---|---|
| `contains` on a `list` field | server |
| `Filter.containsAll(field, values)` | server |
| `Filter.containsAny(field, values)` | fan-out |
| `near` (radius, on a `location` field) | server |

## Existence

`isNull` / `isNotNull` — always **client**. CloudKit has no way to match a missing field.

## OR and ORDER BY

CloudKit only combines predicates with `AND`. `read(entity:any:)` emulates `OR` across branches;
prefer a single `in` filter when branches only differ by value.

`sort:` gives server-side `ORDER BY`.

## Aggregation

Declare `views` on the definition; every write updates counters so reads never scan raw records.

| Operator | Side |
|---|---|
| `COUNT` | write |
| `SUM` / `MIN` / `MAX` | write |
| `AVG` | read |
| `STDDEV` / `VARIANCE` | write + read |
| Percentiles | write + read |
| `GROUP BY` | read |
| `HAVING` | read |
| `DISTINCT` | read |

## Read and write shapes

| Feature | API |
|---|---|
| Projection | `read(entity:filters:fields:)` |
| Streaming | `stream(entity:filters:pageSize:)` |
| Query plan | `explain(entity:filters:sort:)` |
| Batch update | `updateAll(entity:filters:transform:)` |
| Batch delete | `deleteAll(entity:filters:)` |
| Transactions | `transaction { $0.write(...) }`, repaired by `repairTransactions(olderThan:)` |

## Derived transforms

| Transform | Does | Used for |
|---|---|---|
| `lowercase` | lowercase | case-insensitive equality |
| `fold` | lowercase + strip diacritics | accent-insensitive matching |
| `reversed` | reverse the string | server-side `endsWith` |
| `ngrams` | trigrams of the folded value | substring / wildcard prefilter |
| `hour` / `day` / `week` / `month` | bucket a timestamp | time grouping |
| `hmac` | keyed hash | filterable surrogate for an encrypted field |

## Not supported

- Fully server-side substring, wildcard, or regex matching — verification is always client-side.
- Single-query `OR` — it's a query per branch.
- Aggregation over raw records at read time — must be materialized via `views`.
