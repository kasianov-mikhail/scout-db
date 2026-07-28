# Guides

| | Guide | Description |
|:-:|-|-|
| 🧬 | [Schema](schema.md) | Declare fields and constraints with the schema builder, backed by versioned `SchemaDescriptor` records instead of the append-only CloudKit schema. |
| 🔄 | [Migrations](migrations.md) | Publish schema changes as new, immutable entity versions so every record ever written stays readable. |
| 🧩 | [Macros](macros.md) | Map Swift structs to schema fields with `@Entity` instead of raw `[String: RecordValue]` dictionaries. |
| 🔍 | [Filtering](filtering.md) | Chain filters, sorting, and pagination with the query builder. |
| ⚙️ | [Operators](operators.md) | Reference for every comparison and aggregation operator ScoutDB supports. |
| 📊 | [Aggregation](aggregation.md) | Declare `views` that maintain counters, sums, and histograms at write time so reads never scan raw records. |
| 📎 | [Records](records.md) | Assets, entity references with cascading delete, an audit log, and soft-delete/TTL lifecycle. |
| 🔐 | [Security](security.md) | Encrypt payload fields on the client and query them through hashed, filterable surrogates. |
| 📡 | [Sync](sync.md) | Push notifications that say when to read, and live queries wired to SwiftUI. |
| 🧰 | [Operations](operations.md) | Outbox transactions, advisory leases, request pacing, and per-call telemetry. |
