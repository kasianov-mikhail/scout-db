# The @Entity macro

Every example so far writes and reads `[String: RecordValue]` dictionaries. `@Entity`
generates the mapping between a Swift struct and its schema fields, so the store can write
and query typed structs directly instead.

## Declaring an entity type

```swift
@Entity("purchase")
struct Purchase {
    var productId: String?
    var quantity: Int64?
    @Field("amount") var price: Double?
    @Transient var badge: String?
}
```

- The macro name defaults to the type's snake-cased name (`CartEvent` → `cart_event`) — the
  string argument is only needed to override it.
- Every stored property the macro maps must be `Optional`: a record is free to be missing any
  field, and the macro enforces that at compile time.
- `@Field("amount")` maps `price` to the schema field `amount` instead of the snake-cased
  `price`.
- `@Transient` excludes a property from the mapping entirely — use it for view-local state
  that never goes to CloudKit.
- Computed properties are ignored automatically; only stored properties participate.

This expands to conformance to `EntityRepresentable`: `init(record:)`, a `recordValues`
dictionary, and a `fieldName(for:)` lookup from key path to schema field name. The struct's
own field names are unrelated to the `.required`/`.payload` constraints you declare with
`SchemaBuilder` — the macro only maps property ↔ field name, not storage or validation.

## Using it with EntityStore

```swift
try await store.write(Purchase(productId: "sku-1", quantity: 2, price: 25))

let big = try await store.query(Purchase.self)
    .filter(\.quantity > 5)
    .all()
// [Purchase]  — no manual decoding

try await store.update(Purchase.self, uuid: "sku-1") { purchase in
    purchase.quantity = (purchase.quantity ?? 0) + 1
}
```

`filter(\.quantity > 5)` resolves the key path back to the schema field name through the
generated `fieldName(for:)` — filters read the same as the untyped query builder, just
key-path-safe instead of string-keyed.

## Opaque fields

A property typed exactly `RecordValue?` bypasses the usual `String`/`Int`/`Double`/etc.
conversion and is stored/read raw — useful for a field whose type varies by schema version or
that a migration hasn't settled on a Swift type for yet:

```swift
@Entity("event")
struct Event {
    var kind: String?
    var payload: RecordValue?
}
```

## Limitations

- Structs only — classes and enums aren't supported.
- At least one stored, optional property is required.
- A non-optional stored property is a compile error, as is one without an explicit type
  annotation.
- A property's type must conform to `RecordValueConvertible` (`String`, `Int`/`Int64`,
  `Double`, `Date`, `Data`, or an array of one of these) unless it's `RecordValue?`. Custom
  nested types aren't handled.

If you'd rather derive the same conformance from a *published* schema instead of a Swift
declaration — useful for entities defined outside the app, e.g. by another team's service —
see `scoutdb-codegen`, the code-generation counterpart to this macro.
