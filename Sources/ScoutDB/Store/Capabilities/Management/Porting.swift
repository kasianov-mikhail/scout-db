//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// Exports every live record of the entity as JSON — a data dump for
    /// backups, container-to-container transfer, or test seeding.
    ///
    /// Encrypted payload values are exported decrypted when the store has the
    /// key; the dump is plaintext either way, so treat it accordingly.
    ///
    public func export(entity: String) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try await read(entity: entity))
    }

    /// Imports records exported with `export`, upserting them by uuid.
    ///
    /// Every record must belong to the given entity (`invalidValue` otherwise),
    /// and the values are resolved and validated against the current schema —
    /// an import into a newer schema migrates on the way in. Returns how many
    /// records landed.
    ///
    @discardableResult public func importRecords(_ data: Data, entity: String) async throws -> Int {
        let records = try JSONDecoder().decode([EntityRecord].self, from: data)
        if let stray = records.first(where: { $0.entity != entity }) {
            throw SchemaError.invalidValue(stray.entity)
        }
        let batch = records.filter { !$0.deleted }.map { EntityWrite(values: $0.values, uuid: $0.uuid) }
        try await write(batch, entity: entity)
        return batch.count
    }
}
