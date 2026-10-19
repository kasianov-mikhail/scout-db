# Schema evolution

A schema in ScoutDB only moves forward. Each `update()` publishes the next version of the entity.
Records keep the version they were written under and stay readable through it, so publishing never
rewrites or re-imports data.

## Publishing a new version

`update()` takes the full declaration of the new version and compares it with the current one.

```swift
let uncounted = try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("amount", .double)
    .field("date", .timestamp)
    .field("status", .string)
    .update()
// uncounted == ["status"]
```

What happens to each field:

| Change | Result |
|-|-|
| Same name and type | The field keeps its slot. Its records stay visible to filters and sorts. |
| Same name, new type | The field moves to a fresh slot. The old slot is closed at this version. |
| Field left out | The field is closed at this version. Older records still decode it. |
| New name | The field takes the next free slot of its type. |
| Closed field declared again with its old type | The field reopens its last slot instead of taking a fresh one. |
| `.payload` added or removed | The field moves between a typed slot and a payload slot, like a retype. |

A kept field may widen its `.min` and `.max` or drop them. Narrowing them throws, because records
outside the narrower range already exist.

### Renaming a field

There is no rename operation. Leave the old name out and declare the new one. Records written under
older versions decode the field under the name it had in their version.

### What `update()` returns

`update()` returns the names of new fields that no aggregate counts. A new version never builds
aggregates on its own, because a fresh cell would count only the records written after it. For each
returned name, choose one:

- declare `count(by:)` for it in a further version, to count records from then on;
- mark it `.ungrouped`, to say it should stay uncounted;
- ignore it, and read the records when you need numbers for it.

Aggregates declared in an update join the existing ones. An aggregate with the same shape as an
existing one replaces it. An aggregate lapses only when a field it uses is closed.

## What older records can and cannot do

Decoding always works: a record reads through its own version, whatever came later.

The server's view is narrower. A filter or a sort names the slot that the **current** version gives
a field. Records written before a field moved to a new slot do not match filters or sorts on it.
Fields whose slot never moved keep working across all versions.

Aggregates have the same limit. A cell counts what lands after the aggregate is declared, never what
came before.

## Slots across versions

A closed slot stays reserved, so no other field can take it and misread older records. Retyping a
field, or toggling `.payload`, therefore uses a second slot from the pool. An entity that is retyped
many times can exhaust a pool even though the current version has few fields. Reopening a closed
field under its old name and type reuses its slot and costs nothing.

## Migrations

A `Migration` wraps one schema change. Keep every migration you ever wrote in one ordered list, and
run the whole list at launch or from a setup tool:

```swift
struct CreatePurchase: Migration {
    func prepare(on store: EntityStore) async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .double)
            .field("date", .timestamp)
            .create()
    }
}

struct AddPurchaseStatus: Migration {
    func prepare(on store: EntityStore) async throws {
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("amount", .double)
            .field("date", .timestamp)
            .field("status", .string, .defaultValue("placed"))
            .update()
    }
}

try await store.migrate([CreatePurchase(), AddPurchaseStatus()])
```

Rules of `migrate(_:)`:

- It runs the migrations in order and awaits each one before it starts the next.
- There is no transaction. A migration that throws stops the run, and the migrations before it stay
  applied. Fix the failing migration and run the same list again.
- `create()` republishes version 1 over itself, so running it again is safe.
- `update()` always publishes the next version. Running the same list twice adds a version of the
  same shape. This does not change how records read, but it is not a no-op.

### Reverting

`revert(on:)` is optional; the default does nothing. Implement it only for what a store can give
back, such as records a migration seeded.

```swift
try await store.revert([CreatePurchase(), AddPurchaseStatus()])
```

`revert(_:)` runs the migrations newest first and stops at the first error. It does not roll back
the schema: published versions stay published. To undo a schema mistake, publish a further version
that declares the shape you want.
