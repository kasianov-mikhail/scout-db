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
    /// Asset fields are inlined as bytes so the dump is self-contained and
    /// portable — a bare `.asset` value is only a path into an ephemeral
    /// download cache, useless on another machine or container. (Asset *list*
    /// fields have no byte-list representation and are still exported by path.)
    ///
    public func export(entity: String) async throws -> Data {
        let definition = try await registry.definition(for: entity)
        let assetFields = Self.assetFields(of: definition)
        var records = try await read(entity: entity)
        if !assetFields.isEmpty {
            records = try records.map { try Self.inlining(assetFields, of: $0) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(records)
    }

    /// Exports the entity to a file, a page at a time, and answers with how many
    /// records landed.
    ///
    /// The dump of a whole entity is one of the few results that is not worth
    /// holding: ``export(entity:)`` builds every record and the JSON of all of
    /// them in memory at once, while this holds one page and appends. The file
    /// is the same array either way, so `importRecords` reads back what either
    /// wrote. A failure part-way leaves a partial file, which is not valid JSON
    /// — write to a scratch URL and move it into place once the call returns.
    ///
    @discardableResult public func export(entity: String, to url: URL) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let assetFields = Self.assetFields(of: definition)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SchemaError.invalidValue(url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var written = 0
        try handle.write(contentsOf: Data("[".utf8))
        try await forEachPage(entity: entity) { page in
            for record in page {
                let inlined = assetFields.isEmpty ? record : try Self.inlining(assetFields, of: record)
                try handle.write(contentsOf: Data((written == 0 ? "" : ",").utf8))
                try handle.write(contentsOf: try encoder.encode(inlined))
                written += 1
            }
        }
        try handle.write(contentsOf: Data("]".utf8))
        return written
    }

    private static func assetFields(of definition: EntityDefinition) -> Set<String> {
        Set(definition.fields.filter { $0.type == .asset }.map(\.name))
    }

    private static func inlining(_ fields: Set<String>, of record: EntityRecord) throws -> EntityRecord {
        var record = record
        for name in fields {
            guard case .asset(let url)? = record.values[name] else { continue }
            record.values[name] = .bytes(try Data(contentsOf: url))
        }
        return record
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
