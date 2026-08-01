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
        let writer = EntityWriter(
            database: database,
            aggregator: GridAggregator(database: database, slots: slots),
            entity: entity,
            definition: try await registry.definition(for: entity)
        )
        return try await writer.write(batch)
    }
}
