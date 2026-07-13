<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/scoutdb-header-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/scoutdb-header-light.svg">
  <img alt="ScoutDB" src="assets/scoutdb-header-light.svg">
</picture>

[![Swift](https://github.com/kasianov-mikhail/scout-db/actions/workflows/swift.yml/badge.svg)](https://github.com/kasianov-mikhail/scout-db/actions/workflows/swift.yml)
[![Release](https://img.shields.io/github/v/release/kasianov-mikhail/scout-db)](https://github.com/kasianov-mikhail/scout-db/releases)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)
![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20macOS%2013%2B-blue)
[![License](https://img.shields.io/github/license/kasianov-mikhail/scout-db)](LICENSE)

## Description
[ScoutDB](https://github.com/kasianov-mikhail/scout-db) adds entities, migrations, and structured queries on top of CloudKit. Define entities
in code, query them with filters and sorting, aggregate without scanning, and evolve your
schema freely — the CloudKit [schema](Schema) is uploaded once and never touched again.

## Table of Contents
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [License](#license)

## Features

| | | |
|:-:|-|-|
| 🗂 | **Entities** | Declare fields, constraints, defaults, and unique keys with a chainable schema builder — no CloudKit Console clicking. |
| 🔄 | **Migrations** | Rename, retype, add, and remove fields as new schema versions. Old records stay readable forever; nothing is ever re-imported. |
| 🔍 | **Queries** | Filters, sorting, pagination, streaming, full-text search, geo radius, and batch update/delete through a query builder. |
| 📊 | **Aggregation** | Counters, sums, extremes, deviation, and percentiles maintained on write — reads never scan raw records. |
| 🔐 | **Security** | Client-side field encryption with key rotation, filterable hashed surrogates, and trusted-writer filtering for public databases. |
| 📎 | **Assets** | Store files up to 50 MB per field: write `Data`, read `Data`, ScoutDB handles the staging. |
| ⚙️ | **Reliability** | Unique-key upserts, optimistic concurrency, outbox transactions, TTL cleanup, and a change feed for incremental sync. |

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 6.0+
- [Apple Developer](https://developer.apple.com) account with [CloudKit](https://developer.apple.com/icloud/cloudkit/) enabled

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kasianov-mikhail/scout-db.git", from: "0.2.0")
]
```

Upload the [`Schema`](Schema) file to your CloudKit container once, via the
[CloudKit Console](https://icloud.developer.apple.com/dashboard/): select your container,
open **Schema**, and use **Import Schema** to upload the file to the Development environment.

Deploy it to Production from the console when ready — this is the only schema upload the
container will ever need.

## Usage

```swift
import CloudKit
import ScoutDB

let database = CKContainer(identifier: "iCloud.com.example.app").publicCloudDatabase
let registry = SchemaRegistry(database: database)
let store = EntityStore(database: database, registry: registry)

try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("amount", .double)
    .field("date", .timestamp)
    .envelopeDate("date")
    .create()

try await store.write([
    "product_id": .string("sku-42"),
    "amount": .double(29.97),
    "date": .date(.now),
], entity: "purchase")

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
- [Live contract testing](LiveTestHost/README.md)

## License

ScoutDB is available under the MIT license. See the [LICENSE](LICENSE) file for details.
