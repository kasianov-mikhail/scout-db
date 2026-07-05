# Schema

Production CloudKit schemas are append-only: fields, record types, and index modifiers can
never be removed or retyped. ScoutDB inverts the problem — the physical schema knows nothing
about your domain and is uploaded exactly once. Everything mutable lives in versioned `SchemaDescriptor`
records interpreted at runtime.

## Record types

| Type | Purpose |
|---|---|
| `Entity` | every logical record of every entity |
| `Aggregate` | materialized aggregate cells |
| `SchemaDescriptor` | the registry: one immutable record per entity version |
| `User` | dashboard roles |

## Slot pools

A logical record is exactly one `Entity` record. Typed slot pools live side by side, so any
combination of filters runs as a single server query and writes are atomic. Every CloudKit
field type gets an equal pool of 16 (there is no list of `BYTES` or `REFERENCE` in CloudKit):

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

Only fields used in server-side predicates occupy slots; everything else goes to the `payload`
blob (unlimited fields, 1 MB per record). Slots are scoped per entity — every query filters
`entity` — so pools are reused across entities: an entity can use up to 16 filterable fields
of each type, and up to 32 strings counting the searchable pool.

## The 256-field budget

CloudKit caps a record type at 256 fields, and the six system (`___`) fields count:

```
6 system + 5 envelope + 240 slots (15 × 16) + 1 payload = 252 / 256
```

Four fields remain in reserve. Topping up a pool is an additive, backward-compatible schema
append — but it spends from that reserve, so it is not unlimited.

## Envelope

Every `Entity` carries `entity`, `schema_version`, `uuid`, `deleted`, and `expires`. The
`schema_version` selects which view of the entity's fields decodes the record; `deleted` and
`expires` implement soft deletion and TTL.

## Freezing

Validate before the first Production deploy:

```sh
xcrun cktool validate-schema --team-id <team> --container-id <container> \
    --environment development --file Schema
```

Validation checks syntax and limits, not runtime behavior — pair it with a functional
write/read pass on the Development environment. After the Production deploy, guard the file
with the append-only CI check (`.github/workflows/schema.yml`) and the schema consistency
tests, both included in this repository.
