# The @Entity macro

Every example so far writes and reads `[String: RecordValue]` dictionaries. `@Entity`
generates the mapping between a Swift struct and its schema fields, so the store can write
and query typed structs directly instead.

## Table of Contents
- [Declaring an entity type](#declaring-an-entity-type)
- [Using it with EntityStore](#using-it-with-entitystore)
- [Opaque fields](#opaque-fields)
- [Limitations](#limitations)
- [Generating from a published schema](#generating-from-a-published-schema)

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

| Annotation | Effect |
|---|---|
| `@Entity("name")` | maps the struct to a schema entity; defaults to the type's snake-cased name (`CartEvent` → `cart_event`) |
| `@Field("name")` | maps a property to a differently-named schema field |
| `@Transient` | excludes a property from the mapping entirely — view-local state that never goes to CloudKit |

Every stored property the macro maps must be `Optional`: a record is free to be missing any
field, and the macro enforces that at compile time. Computed properties are ignored
automatically; only stored properties participate.

This expands to conformance to `EntityRepresentable`: `init(record:)`, a `recordValues`
dictionary, and a `fieldName(for:)` lookup from key path to schema field name. The struct's
own field names are unrelated to the `.required`/`.payload` constraints you declare with
`SchemaBuilder` — the macro only maps property ↔ field name, not storage or validation.

## Using it with EntityStore

```swift
try await store.write(Purchase(productId: "sku-1", quantity: 2, price: 25))

let big = try await store.query(Purchase.self)
    .filter(\.quantity > 5)
    .take(100)
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

## Generating from a published schema

If you'd rather derive the same conformance from a *published* schema instead of a Swift
declaration — useful for entities defined outside the app, e.g. by another team's service —
`scoutdb-codegen` is the code-generation counterpart to this macro. Export the definitions the
database holds, then let the build plugin turn them into structs:

```swift
try await registry.exportDefinitions(to: sourcesDirectory)   // <entity>.entity.json per entity
```

Add the `CodegenPlugin` build-tool plugin to the target holding those files, and every
`*.entity.json` in it compiles to a `struct` conforming to `EntityRepresentable` — the same
conformance `@Entity` expands to, so queries and writes read identically. The exported JSON is
pretty-printed with sorted keys, so it diffs cleanly under version control.

```swift
.target(name: "App", plugins: [.plugin(name: "CodegenPlugin", package: "scout-db")])
```

The generated struct's fields come from the definition's latest version, named in camelCase.
Reach for the macro when the schema is authored in your app, and for codegen when it isn't.
