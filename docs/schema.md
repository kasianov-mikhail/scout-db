# 🧬 Schema

Production CloudKit schemas are append-only: fields, record types, and index modifiers can
never be removed or retyped. ScoutDB inverts the problem — the physical schema knows nothing
about your domain and is uploaded exactly once. Everything mutable lives in versioned `SchemaDescriptor`
records interpreted at runtime.

## 🧩 Envelope

Every record carries a small envelope alongside your own fields:

| Field | Purpose |
|---|---|
| `entity` | which entity this record belongs to |
| `schema_version` | which version of the entity's fields decodes this record |
| `uuid` | the record's logical identifier |
| `deleted` | soft-delete flag |
| `expires` | TTL cutoff |

## 🧊 Freezing

Validate before the first Production deploy:

```sh
xcrun cktool validate-schema --team-id <team> --container-id <container> \
    --environment development --file Schema
```

Validation checks syntax and limits, not runtime behavior — pair it with a functional
write/read pass on the Development environment. After the Production deploy, guard the file
with the append-only CI check (`.github/workflows/schema.yml`) and the schema consistency
tests, both included in this repository.
