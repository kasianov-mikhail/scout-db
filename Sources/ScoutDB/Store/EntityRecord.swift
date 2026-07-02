//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct EntityRecord: Codable, Equatable, Sendable {
    public let entity: String
    public let uuid: String
    public var schemaVersion: Int
    public var values: [String: RecordValue]
    public var deleted = false

    public init(entity: String, uuid: String, schemaVersion: Int, values: [String: RecordValue], deleted: Bool = false) {
        self.entity = entity
        self.uuid = uuid
        self.schemaVersion = schemaVersion
        self.values = values
        self.deleted = deleted
    }

    public subscript<T: RecordValueConvertible>(name: String) -> T? {
        get { values[name].flatMap(T.init(recordValue:)) }
        set { values[name] = newValue?.recordValue }
    }
}
