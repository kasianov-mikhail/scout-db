//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct EntityRecord: Codable, Equatable, Sendable {
    let entity: String
    let uuid: String
    var schemaVersion: Int
    var values: [String: RecordValue]
    var deleted = false

    subscript<T: RecordValueConvertible>(name: String) -> T? {
        get { values[name].flatMap(T.init(recordValue:)) }
        set { values[name] = newValue?.recordValue }
    }
}
