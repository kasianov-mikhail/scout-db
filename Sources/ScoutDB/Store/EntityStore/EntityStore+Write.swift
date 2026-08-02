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
        return try await write(entity: entity).save(batch)
    }

    func write(entity: String) async throws -> WriteOperation {
        WriteOperation(
            database: database,
            definition: try await registry.definition(for: entity),
            aggregator: GridAggregator(database: database, slots: slots)
        )
    }
}

public struct EntityWrite: Sendable {
    public let values: [String: RecordValue]
    public let uuid: String?

    public init(values: [String: RecordValue], uuid: String?) {
        self.values = values
        self.uuid = uuid
    }
}
