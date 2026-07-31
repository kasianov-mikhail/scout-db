//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    @discardableResult public func write<T: EntityRepresentable>(_ item: T, uuid: String? = nil) async throws -> String {
        try await write(item.recordValues, entity: T.entityName, uuid: uuid)
    }

    @discardableResult public func write<T: EntityRepresentable>(_ items: [T]) async throws -> [String] {
        try await write(items.map { EntityWrite(values: $0.recordValues) }, entity: T.entityName)
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
