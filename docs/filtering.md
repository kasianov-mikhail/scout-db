# Filtering

Open a query with `store.query(_:)`, chain clauses, finish with an executor:

```swift
let failures = try await store.query("log")
    .filter("level", .equals, "error")
    .filter("date" > .date(yesterday))
    .sort("date", .descending)
    .limit(50)
    .all()
```

Executors: `all()`, `first()`, `count()`, `paginate(size:after:)`, `stream(pageSize:)`,
`update(_:)`, `delete()`, and `explain()`.

## Operator sugar

```swift
.filter("quantity" > 5)          // ranges: > >= < <=
.filter("state" != 0)            // inequality
.filter("title" ~~ "cloud")      // contains: substring or list membership
.filter("name" =~ "cart_")       // prefix
.filter("level", .equals, "err") // any operator by name — always works
```

String equality via `==` collides with Swift's own `String == String`, so spell it
`.filter("field", .equals, "value")`.

## OR groups

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

## Server or client?

Every filter runs server-side when CloudKit can express it and as a client-side matcher on
the fetched results otherwise — see the side column in [Operators](operators.md).
`explain()` shows the exact split for a query. Client-side matchers scan the server-filtered
set, so pair them with at least one selective server predicate on large entities.

## Shadow fields

Three matching capabilities CloudKit lacks are recovered by declaring a derived shadow field
once; the matching operators pick it up automatically:

```swift
.field("title", .string)
.field("title_rev",   .string,     .derived(from: "title", .reversed))  // server-side endsWith
.field("title_fold",  .string,     .derived(from: "title", .fold))      // case/diacritic-insensitive
.field("title_grams", .stringList, .derived(from: "title", .ngrams))    // substring prefilter
```

- `reversed` turns `endsWith` into a server-side prefix query.
- `fold` holds the lowercased, diacritic-stripped value; query it with a pre-folded needle.
- `ngrams` holds trigrams of the folded value; `contains` and `like` use it to narrow the
  scan server-side before the exact client-side check.

## Existence and projections

`isNull` / `isNotNull` are always client-side — CloudKit cannot match a missing field — and
work on payload fields too. Projections fetch only what you name:

```swift
.fields("product_id", "amount")
```
