//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// Tombstones every record of the entity, then retires its schema.
    ///
    /// Returns how many records were tombstoned. The tombstones stay behind for
    /// change feeds; republishing the schema brings the entity back, without its
    /// dropped records.
    ///
    @discardableResult public func drop(entity: String) async throws -> Int {
        let removed = try await deleteAll(entity: entity)
        try await registry.retire(entity: entity)
        return removed
    }
}
