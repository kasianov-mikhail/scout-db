//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    @discardableResult public func write(_ batch: [EntityWrite], entity: String) async throws -> [String] {
        guard batch.count > 0 else {
            return []
        }
        let writer = WriteOperation(
            database: database,
            aggregator: GridAggregator(database: database, slots: slots),
            entity: entity,
            definition: try await registry.definition(for: entity)
        )
        return try await writer.write(batch)
    }
}

/// One record of a batched `EntityStore.write(_:entity:)` call.
public struct EntityWrite: Sendable {
    public let values: [String: RecordValue]

    /// The uuid to write under, replacing any record that already carries it,
    /// or `nil` to write under a fresh one that no stored record can hold.
    public let uuid: String?

    public init(values: [String: RecordValue], uuid: String?) {
        self.values = values
        self.uuid = uuid
    }
}
