//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// Writes a batch of records and answers the uuid each one was stored
    /// under, one per record rather than one per entry.
    ///
    /// An entry carrying a uuid upserts under it, and one leaving it nil takes
    /// a fresh uuid. Two entries naming the same uuid describe one record, so
    /// the last of them stands and the rest are folded into it before anything
    /// is written — a batch is one request, and a request carries a record
    /// once.
    ///
    /// ```swift
    /// let uuids = try await store.write(
    ///     [EntityWrite(values: ["product_id": .string("sku-42")], uuid: nil)],
    ///     entity: "purchase"
    /// )
    /// ```
    ///
    @discardableResult public func write(_ batch: [EntityWrite], entity: String) async throws -> [String] {
        guard batch.count > 0 else {
            return []
        }
        return try await write(entity: entity).save(batch)
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
