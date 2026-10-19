# Testing

The `ScoutDBTesting` library runs the whole store in memory: schema publishing, writes, queries,
pagination and aggregates. Tests need no network, no iCloud account and no CloudKit container.

Add it to the test target only:

```swift
.testTarget(
    name: "AppTests",
    dependencies: [
        .product(name: "ScoutDB", package: "scout-db"),
        .product(name: "ScoutDBTesting", package: "scout-db"),
    ]
)
```

## InMemoryDatabase

`InMemoryDatabase` implements the same `CloudDatabase` protocol as `CKDatabase` and evaluates the same
`CKQuery` predicates and sort descriptors. Wire it exactly like the real database:

```swift
import ScoutDB
import ScoutDBTesting
import Testing

@Test func paidPurchasesAreCounted() async throws {
    let database = InMemoryDatabase()
    let store = EntityStore(database: database, registry: SchemaRegistry(database: database))

    try await store.schema("purchase")
        .field("status", .string, .required)
        .create()

    try await store.write(
        [
            EntityWrite(values: ["status": "paid"], uuid: nil),
            EntityWrite(values: ["status": "placed"], uuid: nil),
        ],
        entity: "purchase"
    )

    let paid = try await store.query("purchase").filter("status", .equals, "paid").count()
    #expect(paid == 1)
}
```

The double is safe for concurrent use. Every call holds a lock for the whole operation, so parallel
reads and writes see whole records.

It also enforces CloudKit's record name rules. A uuid that the server would refuse is refused here
too.

## Request budgets

`requests` counts the calls the double has served, by kind. Use it to check that a code path stays
within a request budget, independent of the data it leaves behind.

```swift
database.resetRequests()

_ = try await store.query("purchase").totals(metric: .sum, group: "status")

#expect(database.requests[.query] == 0)
#expect(database.requests.total <= 4)
```

`RequestTally` reports:

| Member | Meaning |
|-|-|
| `total` | All calls. |
| `[kind]` | Calls of one kind: `.query`, `.continuation`, `.modify`, `.conditionalSave`, `.fetch`. |
| `records` | Records the calls carried: results for reads, inputs for writes. |
| `failures` | Calls that threw. |

`resetRequests()` clears the tally and keeps the stored records.

## Simulating CloudKit behavior

| Property | Effect |
|-|-|
| `pageLimit` | Caps every response page, like the CloudKit server does. Set it to force multi-page reads. |
| `unindexed` | Record IDs that queries do not see yet, while fetches by ID still return them. Simulates index lag. |
| `errors` | Errors to throw from the next calls of any kind. The last element is thrown first. |
| `writeErrors` | Errors to throw from the next writes only. They are used before `errors`. |
| `records` | Every stored `CKRecord`. Read it to inspect raw storage, or set it to seed or replace the data. |

```swift
database.pageLimit = 2
database.errors = [CKError(.networkUnavailable)]

await #expect(throws: (any Error).self) {
    try await store.query("purchase").take(10)
}
```

For a record in the double, `overrideModificationDate(_:)` and `overrideChangeTag(_:)` stamp the
metadata that the server normally sets. `recordModificationDate` and `recordVersionTag` read it back.

## InMemoryContainer

`InMemoryContainer` stands in for `CKContainer` where code checks the account status. Its
`publicDatabase` is a fresh `InMemoryDatabase`.

```swift
let container = InMemoryContainer(status: .noAccount)

await #expect(throws: (any Error).self) {
    try await container.requireAccount()
}
```

To share one container between the app and tests, have the app code take any `CloudContainer`.
`CKContainer` conforms to it.
