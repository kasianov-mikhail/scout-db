<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/scoutdb-header-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/scoutdb-header-light.svg">
  <img alt="ScoutDB" width="495" height="144" src="assets/scoutdb-header-light.svg">
</picture>

<br/>
<br/>

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
- [Testing without a container](#testing-without-a-container)
- [Documentation](#documentation)
- [License](#license)

## Features

| | | |
|:-:|-|-|
| 🗂 | **Schema** | Declare fields, constraints, and defaults with a chainable schema builder, then rename, retype, add, or remove fields as new schema versions — old records stay readable forever, nothing is ever re-imported. |
| 🔍 | **Queries** | Filters, sorting, keyset pagination, and full-text search through a query builder, plus counters, sums, and extremes maintained on write so reads never scan raw records. |
| ⚙️ | **Reliability** | Writes that carry a uuid upsert, and aggregate cells folded under compare-and-swap. |

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

The physical CloudKit schema ships as the [`Schema`](Schema) file at the repository root.
Upload it once per container through the
[CloudKit Console](https://icloud.developer.apple.com/dashboard/): select your container, open
**Schema**, and use **Import Schema** to upload the file to the Development environment.

Deploy to Production from the CloudKit Console when ready. After that the file is frozen —
every schema change in your app is a data change, not a re-import.

## Usage

### Connect

```swift
import CloudKit
import ScoutDB

let database = CKContainer(identifier: "iCloud.com.example.app").publicCloudDatabase
let registry = SchemaRegistry(database: database)
let store = EntityStore(database: database, registry: registry)
```

ScoutDB runs against the public database only — the shipped `Schema`, its role grants, and
the default zone every request names describe that scope. The private and shared databases
are out of scope, so `CloudContainer` hands out `publicDatabase` and nothing else.

### Declare an entity

```swift
try await store.schema("purchase")
    .field("product_id", .string, .required)
    .field("quantity", .int, .minimum(0))
    .field("amount", .double)
    .field("date", .timestamp)
    .field("comment", .string, .payload)
    .create()
```

Fields marked `.payload` take a slot of the payload pool, sixteen deep, and skip server-side
filtering — use it for everything you never filter on.

### Write and query

```swift
try await store.write(
    [
        EntityWrite(values: [
            "product_id": .string("sku-42"),
            "quantity": .int(3),
            "amount": .double(29.97),
            "date": .date(.now),
        ])
    ],
    entity: "purchase"
)

let recent = try await store.query("purchase")
    .filter("quantity" > 1)
    .sort("date", .reverse)
    .take(20)
```

## Testing without a container

The package ships a second library, `ScoutDBTesting`, whose `InMemoryDatabase` implements the
same `CloudDatabase` protocol the real one does — so a test drives the whole store, schema
publishing included, without a network or an iCloud account:

```swift
import ScoutDBTesting

let database = InMemoryDatabase()
let store = EntityStore(database: database, registry: SchemaRegistry(database: database))
```

`InMemoryContainer` stands in for `CloudContainer` when the code under test checks account
status, and it can be made to report any `CKAccountStatus` you want to exercise.

## License

ScoutDB is available under the MIT license. See the [LICENSE](LICENSE) file for details.
