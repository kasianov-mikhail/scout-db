# 📚 Guides

| | Guide | Description |
|:-:|-|-|
| 🚀 | [Getting Started](getting-started.md) | Install the package and upload the physical [`Schema`](../Schema) once through the CloudKit Console. |
| 🧬 | [Schema](schema.md) | Declare fields and constraints with the schema builder, backed by versioned `SchemaDescriptor` records instead of the append-only CloudKit schema. |
| 🔄 | [Migrations](migrations.md) | Publish schema changes as new, immutable entity versions so every record ever written stays readable. |
| 🧩 | [Macros](macros.md) | Map Swift structs to schema fields with `@Entity` instead of raw `[String: RecordValue]` dictionaries. |
| 🔍 | [Filtering](filtering.md) | Chain filters, sorting, and pagination with the query builder. |
| ⚙️ | [Operators](operators.md) | Reference for every comparison and aggregation operator ScoutDB supports. |
| 📊 | [Aggregation](aggregation.md) | Declare `views` that maintain counters, sums, and histograms at write time so reads never scan raw records. |
| 📎 | [Records](records.md) | Assets, entity references with cascading delete, an audit log, and soft-delete/TTL lifecycle. |
| 🔐 | [Security](security.md) | Encrypt payload fields on the client and query them through hashed, filterable surrogates. |
| 🔗 | [Sharing](sharing.md) | Share a zone or single record with `CKShare` and accept invitations by URL. |
| 📡 | [Sync](sync.md) | Walk the zone change feed in resumable batches, wired to push notifications and SwiftUI. |
| 📴 | [Offline](offline.md) | Queue writes and replay cached reads with `OfflineCache`, or mirror whole zones with `ReplicaCache`. |
