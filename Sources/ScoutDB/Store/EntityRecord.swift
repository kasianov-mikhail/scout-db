//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One record of an entity, decoded through the version it was written under.
///
/// The values are keyed by field name, whatever slot or payload they came out
/// of; reach for the typed subscript rather than unwrapping a `RecordValue` by
/// hand.
///
public struct EntityRecord: Codable, Equatable, Sendable {
    /// The entity the record belongs to.
    public let entity: String

    /// The record's logical identifier, stable across updates and derived from
    /// the definition's `unique` fields when it declares them.
    public let uuid: String

    /// The definition version the values are read and written through.
    public var schemaVersion: Int

    /// The record's fields, keyed by name.
    public var values: [String: RecordValue]

    /// Whether the record is a tombstone — deletes soft-delete by default, so
    /// other devices can sync the removal.
    public var deleted = false

    public init(entity: String, uuid: String, schemaVersion: Int, values: [String: RecordValue], deleted: Bool = false) {
        self.entity = entity
        self.uuid = uuid
        self.schemaVersion = schemaVersion
        self.values = values
        self.deleted = deleted
    }

    /// Reads or writes the named field as the Swift type in play, `nil` when
    /// the field is absent or holds something else.
    public subscript<T: RecordValue.Convertible>(name: String) -> T? {
        get { values[name].flatMap(T.init(recordValue:)) }
        set { values[name] = newValue?.recordValue }
    }
}
