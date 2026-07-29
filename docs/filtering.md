# Filtering

Open a query with `store.query(_:)`, chain clauses, finish with an executor:

```swift
let failures = try await store.query("log")
    .filter("level", .equals, "error")
    .filter("date" > .date(yesterday))
    .sort("date", .descending)
    .take(50)
```

| Executor | Returns |
|---|---|
| `take(_:)` | at most that many matching records |
| `first()` | the first matching record, if any |
| `count()` | the number of matches |
| `paginate(size:after:)` | one page ordered by the envelope date, plus a cursor for the next |
| `page(size:after:)` | one page ordered by the query's own `sort` clause, plus a cursor |
| `stream(pageSize:)` | an async sequence of pages |
| `update(_:)` | applies a transform to every match |
| `delete()` | deletes every match |
| `observe()` / `live()` | the result, re-delivered on every local mutation — see [Sync](sync.md) |
| `explain()` | the query plan, one per OR branch, for debugging |

Keyset pagination picks its order up front: `paginate(size:after:)` is ordered by the envelope
date and throws rather than silently dropping a `sort` clause, while `page(size:after:)`
requires exactly one `sort` on a slot-backed scalar field.

The clauses in between are `filter`, `exclude`, `group`, `sort`, `nearest(_:latitude:longitude:)`
for a nearest-first distance order, `fields` for a projection, `limit`, and `createdBy`.

## Table of Contents
- [Folds](#folds)
- [Creator scope](#creator-scope)
- [Operator sugar](#operator-sugar)
- [OR groups](#or-groups)
- [Exclusions](#exclusions)
- [Performance](#performance)
- [Shadow fields](#shadow-fields)
- [Existence and projections](#existence-and-projections)

## Folds

Numbers over the matching records, fetching only the folded field — no view required:

```swift
let revenue = try await store.query("purchase").filter("status", .equals, "paid").sum("amount")
let peak    = try await store.query("purchase").maximum("amount")
let perUser = try await store.query("purchase").sum("amount", by: "user_id")
let perKind = try await store.query("purchase").count(by: "status")
```

`sum`, `minimum`, `maximum`, and `average` each take a `by:` grouping variant, as `count`
does. These scan what the query selects — a declared view answers `count()`, and an `exact`
`min`/`max` view answers `minimum()`/`maximum()`, from the grid instead. See
[Aggregation](aggregation.md).

## Creator scope

`createdBy(_:)` keeps only the records a given user wrote, matched server-side on
`creatorUserRecordID` — the public-database pattern. It is part of the query, so every
executor honors it: the folds and `count(by:)` as much as `take(_:)`, and a scoped `update(_:)`
or `delete()` never touches another user's records.

```swift
try await store.query("purchase").createdBy(me).sum("total")
```

A scoped fold or count always reads records: an aggregate view's grid folds every writer's
contributions together and cannot be split back by creator.

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

## Exclusions

`exclude(_:_:_:)` keeps the records a predicate does *not* match:

```swift
.exclude("status", .equals, "archived")
```

A negated comparison, equality or `in` runs on the server as its complementary operator —
`!=`, `>=`, `NOT IN` — as long as the field is declared `.required` or carries a
`.defaultValue`, so that no record can be missing it. Every other negation is evaluated
client-side after decoding, and there a record missing the field is kept.

## Performance

Some operators (`matches`, `isNull`, substring `contains` without a shadow field) scan the
records the rest of the query selects — on large entities, combine them with at least one
selective filter such as an equality or a date range. `explain()` prints the plan of a query
when in doubt.

## Shadow fields

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

The planner finds a shadow by its derivation, not its name, so the name above is yours to
pick.

A shadow is recomputed on every write, so records written before you declared one carry it
only after a `Migrator.backfill(entity:)` pass.

## Existence and projections

`isNull` / `isNotNull` are always client-side — CloudKit cannot match a missing field — and
work on payload fields too. Projections fetch only what you name:

```swift
.fields("product_id", "amount")
```
