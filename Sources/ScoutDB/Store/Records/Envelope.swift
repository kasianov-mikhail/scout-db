//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

enum Envelope {
    static let entity = "s_00"
    static let version = "i_00"
    static let uuid = "s_01"
}

extension FieldType {
    var reserved: Int {
        switch self {
        case .string:
            2
        case .int:
            1
        default:
            0
        }
    }
}
