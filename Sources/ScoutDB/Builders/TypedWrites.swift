//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// Writes a typed value through its derived field map.
    ///
    /// The value's nil properties stay out of the write entirely, and fields
    /// the type does not map are untouched — a typed write only speaks for
    /// the fields it knows. Returns the stored uuid, which a `unique(on:)`
    /// entity derives from the value itself.
    ///
    @discardableResult public func write<T: EntityRepresentable>(_ item: T, uuid: String = UUID().uuidString) async throws -> String {
        try await write(item.recordValues, entity: T.entityName, uuid: uuid)
    }

    /// Writes a batch of typed values in one chunked save, under fresh uuids.
    ///
    /// Returns the stored uuid of every value, in batch order.
    ///
    @discardableResult public func write<T: EntityRepresentable>(_ items: [T]) async throws -> [String] {
        try await write(items.map { EntityWrite(values: $0.recordValues, uuid: UUID().uuidString) }, entity: T.entityName)
    }

    /// Rewrites one record through its Swift type, with the usual
    /// conditional-save retry loop.
    ///
    /// The transform edits the decoded value; only the fields it maps flow
    /// back, so payload and unmapped fields survive untouched. Setting a
    /// mapped property to nil leaves the stored field as it was — clearing a
    /// field takes the untyped `update(entity:uuid:transform:)`.
    ///
    public func update<T: EntityRepresentable>(
        _ type: T.Type = T.self, uuid: String, maxRetry: Int = 3, transform: (inout T) throws -> Void
    ) async throws {
        try await update(entity: T.entityName, uuid: uuid, maxRetry: maxRetry) { record in
            var item = T(record: record)
            try transform(&item)
            for (field, value) in item.recordValues {
                record.values[field] = value
            }
        }
    }
}
