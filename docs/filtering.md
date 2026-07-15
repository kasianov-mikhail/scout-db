# 🔍 Filtering

Open a query with `store.query(_:)`, chain clauses, finish with an executor:

```swift
let failures = try await store.query("log")
    .filter("level", .equals, "error")
    .filter("date" > .date(yesterday))
    .sort("date", .descending)
    .limit(50)
    .all()
```

| Executor | Returns |
|---|---|
| `all()` | every matching record |
| `first()` | the first matching record, if any |
| `count()` | the number of matches |
| `paginate(size:after:)` | one page plus a cursor for the next |
| `stream(pageSize:)` | an async sequence of pages |
| `update(_:)` | applies a transform to every match |
| `delete()` | deletes every match |
| `explain()` | the query plan, for debugging |

## 🧪 Operator sugar

```swift
.filter("quantity" > 5)          // ranges: > >= < <=
.filter("state" != 0)            // inequality
.filter("title" ~~ "cloud")      // contains: substring or list membership
.filter("name" =~ "cart_")       // prefix
.filter("level", .equals, "err") // any operator by name — always works
```

String equality via `==` collides with Swift's own `String == String`, so spell it
`.filter("field", .equals, "value")`.

## 🔀 OR groups

CloudKit combines predicates with `AND` only. A group of alternatives is `OR`-ed inside and
`AND`-ed with the rest of the query; behind the scenes it fans out into one server query per
branch:

```swift
.group {
    $0.filter("level", .equals, "error")
    $0.filter("level", .equals, "fatal")
}
```

Prefer a single `in` filter when the branches only differ by one field's value.

## ⚡ Performance

Some operators (`matches`, `isNull`, substring `contains` without a shadow field) scan the
records the rest of the query selects — on large entities, combine them with at least one
selective filter such as an equality or a date range. `explain()` prints the plan of a query
when in doubt.

## 👻 Shadow fields

Three matching capabilities CloudKit lacks are recovered by declaring a derived shadow field
once; the matching operators pick it up automatically:

```swift
.field("title", .string)
.field("title_rev",   .string,     .derived(from: "title", .reversed))  // server-side endsWith
.field("title_fold",  .string,     .derived(from: "title", .fold))      // case/diacritic-insensitive
.field("title_grams", .stringList, .derived(from: "title", .ngrams))    // substring prefilter
```

| Derivation | Recovers |
|---|---|
| `reversed` | server-side `endsWith`, as a prefix query |
| `fold` | case/diacritic-insensitive matching |
| `ngrams` | a substring prefilter, narrowed further client-side |

## 🎯 Existence and projections

`isNull` / `isNotNull` are always client-side — CloudKit cannot match a missing field — and
work on payload fields too. Projections fetch only what you name:

```swift
.fields("product_id", "amount")
```
