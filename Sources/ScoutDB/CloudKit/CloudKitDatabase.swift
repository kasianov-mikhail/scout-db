//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    /// Creates a store backed by a CloudKit database.
    public init(database: CKDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil, trustedWriters: Set<String>? = nil) {
        self.init(database: database as any CloudDatabase, registry: registry, keyProvider: keyProvider, trustedWriters: trustedWriters)
    }
}

extension SchemaRegistry {
    /// Creates a registry backed by a CloudKit database.
    public init(database: CKDatabase) {
        self.init(database: database as any CloudDatabase)
    }
}

extension Migrator {
    /// Creates a migrator backed by a CloudKit database.
    public init(database: CKDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil) {
        self.init(database: database as any CloudDatabase, registry: registry, keyProvider: keyProvider)
    }
}
