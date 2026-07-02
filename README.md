# ScoutDB

A schema-registry layer on top of CloudKit. The physical CloudKit schema (`Schema` at the
repository root) is uploaded once and frozen; every logical schema change afterwards is a data
change — a new `Meta` record — so migrations never touch `cktool import-schema` again.

## Quick start

```swift
let store = UniversalStore(database: container.publicCloudDatabase, registry: registry)

try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("amount", .double)
    .field("date", .timestamp)
    .envelopeDate("date")
    .create()

let recent = try await store.query("purchase")
    .filter("amount" > 10)
    .sort("date", .descending)
    .limit(20)
    .all()
```

## Documentation

- [Getting started](docs/getting-started.md)
- [Schema](docs/schema.md)
- [Migrations](docs/migrations.md)
- [Filtering](docs/filtering.md)
- [Operators](docs/operators.md)
- [Aggregation](docs/aggregation.md)
- [Security](docs/security.md)

## Why

Production CloudKit schemas are append-only: fields, record types, and index modifiers can never
be removed or retyped. This module inverts the problem — the physical schema knows nothing about
the domain, and everything mutable (entity names, field names, types, constraints, views) lives
in versioned `Meta` records interpreted at runtime.

## Physical schema

Four frozen record types. A logical record is exactly one `Item` record: typed slot pools live
side by side, so any combination of filters runs as a single server query and writes are atomic.

| Type | Fields | Purpose |
|---|---|---|
| `Item` | envelope + slot pools + `asset` + `payload` | every logical record of every entity |
| `GridItem` | `entity`, `view`, `group_key`, `date`, `c_00…c_63`, `f_00…f_63` | materialized aggregate cells: counts and sums |
| `Meta` | `entity`, `entity_version`, `definition`, `status` | the registry: one immutable record per entity version |
| `Users` | `roles` | dashboard roles |

`Item` slot pools — only fields used in server-side predicates occupy slots; everything else
goes to the `payload` blob. Slots are scoped per entity (every query filters `entity`), so pools
are reused across entities. Every CloudKit field type gets an equal pool of 16 — 9 scalar
(prefix = first letter) and 6 list (prefix `l` + element letter). CloudKit has no list of BYTES
or REFERENCE, so those lists are absent:

| Scalar | | List | |
|---|---|---|---|
| `s_` | STRING | `ls_` | LIST\<STRING\> |
| `x_` | STRING + SEARCHABLE | `li_` | LIST\<INT64\> |
| `i_` | INT64 | `ld_` | LIST\<DOUBLE\> |
| `d_` | DOUBLE | `lt_` | LIST\<TIMESTAMP\> |
| `t_` | TIMESTAMP | `lg_` | LIST\<LOCATION\> |
| `b_` | BYTES | `la_` | LIST\<ASSET\> |
| `g_` | LOCATION | | |
| `r_` | REFERENCE | | |
| `a_` | ASSET | | |

Slots run `00…15`. Envelope on every `Item`: `entity`, `schema_version`, `uuid`, `deleted`,
`expires`. Write an asset as `.bytes(data)` — it is staged to a file automatically; read it back
with `record.assetData(for:)`.

CloudKit caps a record type at 256 fields — the 6 system (`___`) fields count too. Budget:
6 system + 5 envelope + 240 slots (15 × 16) + 1 payload = 252, leaving 4 free. A pool top-up
spends from that headroom.

## Definition format

A `Meta` record carries a JSON `EntityDefinition`:

```json
{
  "entity": "purchase",
  "version": 3,
  "envelopeDate": "date",
  "unique": ["user_id", "date"],
  "keyID": "k1",
  "ttl": 7776000,
  "views": [{ "name": "hourly", "groupBy": "product_id", "bucket": "hour" }],
  "fields": [
    { "name": "product_id", "type": "string",    "storage": "s_00", "required": true },
    { "name": "date",       "type": "timestamp", "storage": "t_00" },
    { "name": "day",        "type": "timestamp", "storage": "t_01",
      "derived": { "source": "date", "transform": "day" } },
    { "name": "level",      "type": "string",    "storage": "s_01",
      "allowed": ["info", "error"], "default": { "string": "info" } },
    { "name": "amount",     "type": "int",       "storage": "i_00", "until": 2 },
    { "name": "total",      "type": "double",    "storage": "d_00", "since": 2, "minimum": 0 },
    { "name": "email",      "type": "string",    "storage": "payload", "encrypted": true },
    { "name": "email_hash", "type": "string",    "storage": "s_02",
      "derived": { "source": "email", "transform": "hmac" } }
  ]
}
```

- `since` / `until` bound a field to a version range, so one definition decodes every record
  ever written; `schema_version` on the record selects the right view of the fields.
- Renames keep the `storage` and change the `name`; type changes move to a new slot. Freed slots
  must not be reassigned while records of the old versions still exist.
- `unique` derives the record `uuid` from a SHA-256 of the listed field values — writes become
  deduplicating upserts.
- `derived` fields are materialized by the coder on every write: time buckets (`hour`, `day`,
  `week`, `month`), `lowercase` normalization, and keyed `hmac` surrogates.
- `encrypted` payload fields are sealed with AES-GCM; `keyID` names the symmetric key resolved
  through `EncryptionKeyProvider` (Keychain or your backend — never CloudKit). Readers without
  the key see ciphertext and can still filter by the `hmac` surrogate slot.
- `ttl` stamps an `expires` envelope field from `envelopeDate`; `reap(entity:asOf:)` tombstones
  expired records with a server-side predicate.
- `views` maintain `GridItem` counters on every write (CAS via record etag): one grid record per
  group and period, cells indexed by `bucket` (`hour`, `weekday`, `day`). Counts go to `c_*`
  cells; an optional `sum` field accumulates into the matching `f_*` cell, so averages are
  `f / c` at read time.
- `references` marks a field as a foreign key for `join`, `orphans`, and cascading `delete`.

## Components

| Type | Role |
|---|---|
| `SchemaRegistry` | loads, caches, validates, and publishes `Meta` definitions; `preload()` warms the whole catalog in one query |
| `UniversalCoder` | logical values ↔ `Item` record: defaults, constraints, derived fields, encryption, TTL, payload |
| `UniversalStore` | write / read / update (CAS) / delete / change feed / keyset pagination / reap / relations |
| `UniversalMigrator` | backfill: re-encodes old-version records at the latest version; idempotent by construction, safe to re-run after interruption |
| `GridAggregator` | on-write hook that increments aggregate grid cells |
| `DefinitionCodeGenerator` | typed Swift wrappers generated from a definition |

## Capabilities beyond raw CloudKit

- Rename and retype fields and entities; delete and resurrect them — all as `Meta` inserts,
  including reverse migrations (backfill can target an older version).
- Unique constraints and upserts (deterministic record IDs).
- Validation on the write path: required fields, enum domains, numeric ranges, defaults.
- Case-insensitive matching via `lowercase` shadow slots.
- Change feed: `store.changes(entity:since:)` polls `___modTime` as a cursor, tombstones included.
- Soft deletes (`deleted`), TTL retention (`expires` + `reap`).
- Entity-level compare-and-swap with retries on `RecordConflictError`.
- Durable keyset pagination (`date` + `uuid` cursor) instead of expiring CloudKit query cursors.
- Field-level encryption with key rotation via per-version `keyID`.
- Tag membership (`contains`) and radius (`near`) server-side predicates.
- Referential integrity: `join`, `orphans`, cascading `delete`.
- Trusted-writer filtering by the server-set `___createdBy` (anti-vandalism for the public database).

Recipes intentionally left to callers (thin compositions of the above): offline mirrors on top of
`changes()`, JSON backup/restore via `changes()` + `write`, outbox-style multi-record transactions.

## Matching operators

`UniversalStore.Filter` accepts a `Match` operator; the store splits filters into predicates
CloudKit runs server-side and matchers applied client-side after decoding. The full operator
reference — comparison, string matching, shadow-slot techniques, existence checks, and
aggregation — lives in [docs/operators.md](docs/operators.md).

## Limits that remain

- Fields stored in `payload` cannot be filtered or sorted server-side — promote them to a slot.
- No server-side aggregation or joins — aggregates are materialized via `views`.
- The `contains` / `near` operators and the `location` value case need scout-server support
  before hosted backends can use them.

## Invariants (CI-enforced expectations)

1. The physical `Schema` file never changes after the initial import (append-only at most).
2. A slot is never reassigned while records of versions that used it still exist.
3. Canonical slots for shared fields (`user_id`, `session_id`, …) stay identical across entities.
4. `Meta` versions are immutable: a change is always a new `entity_version`.
