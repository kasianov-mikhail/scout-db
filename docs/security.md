# Security

## Field encryption

The public database is world-readable, so sensitive values are encrypted on the client
before they leave the device. Mark a payload field `.encrypted`, name the key, and provide
it through `EncryptionKeyProvider` — from the Keychain or your own backend, never CloudKit:

```swift
try await store.schema("account")
    .field("email", .string, .payload, .encrypted)
    .field("email_hash", .string, .derived(from: "email", .hmac))
    .keyID("k1")
    .create()

let store = UniversalStore(database: database, registry: registry, keyProvider: provider)
```

Values are sealed with AES-GCM. Readers without the key see ciphertext and simply get `nil`
for the field; readers with the key decrypt transparently. Key rotation is a new definition
version with a new `keyID`.

## HMAC surrogates

An encrypted field cannot be filtered — the `hmac` derivation materializes a keyed hash of
the value into a slot, so equality lookups still run server-side:

```swift
.filter("email_hash", .equals, .string(hashedNeedle))
```

The surrogate reveals nothing about the value, but matches deterministically.

## Trusted writers

Anyone with an iCloud account can write to a public database. CloudKit stamps every record
with its creator (`___createdBy`) server-side — it cannot be forged — so a reader can drop
records from unknown writers:

```swift
let store = UniversalStore(database: database, registry: registry, trustedWriters: ["_abc123"])
```

Grants cannot be narrowed after the fact, so this reader-side filter is the practical
anti-vandalism tool for world-writable containers.

## Limits

- Encrypted fields support exact-match lookups via the surrogate only — no ranges, no
  substring search.
- Key distribution is the application's problem: ScoutDB takes a provider, not a policy.
- `payload` and slot values are visible to anyone who can read the container; encrypt what
  must not be public, or do not write it at all.
