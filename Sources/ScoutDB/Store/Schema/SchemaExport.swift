//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    /// The canonical `.entity.json` bytes the codegen toolchain consumes.
    ///
    /// Formatting is stable — pretty-printed with sorted keys — so exports
    /// diff cleanly under version control.
    ///
    public func exportedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension SchemaRegistry {
    /// Writes every active definition to `directory` as `<entity>.entity.json`.
    ///
    /// The round trip back into the toolchain: exported files feed
    /// `scoutdb-codegen` and the build plugin, so a schema authored in code and
    /// published to the database can be turned into typed structs elsewhere.
    /// Preloads the active set first, so the export covers the database's
    /// schema rather than just what this process has read. Returns the files
    /// written, ordered by entity.
    ///
    @discardableResult public func exportDefinitions(to directory: URL) async throws -> [URL] {
        try await preload()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for definition in definitions().sorted(by: { $0.entity < $1.entity }) {
            let url = directory.appendingPathComponent("\(definition.entity).entity.json")
            try definition.exportedJSON().write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }
}
