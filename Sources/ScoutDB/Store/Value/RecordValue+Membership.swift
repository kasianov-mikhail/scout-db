//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    static func membership(of values: [RecordValue]) -> RecordValue? {
        switch values.first {
        case .string:
            homogeneous(values, of: String.self)
        case .int:
            homogeneous(values, of: Int64.self)
        case .double:
            homogeneous(values, of: Double.self)
        case .date:
            homogeneous(values, of: Date.self)
        default:
            nil
        }
    }

    private static func homogeneous<T: RecordListElement>(_ values: [RecordValue], of _: T.Type) -> RecordValue? {
        let members = values.compactMap(T.init(recordValue:))
        return members.count == values.count ? T.list(members) : nil
    }
}
