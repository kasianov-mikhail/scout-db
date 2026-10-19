//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    static func membership(values: [RecordValue]) -> RecordValue? {
        switch values.first {
        case .string:
            homogeneous(values: values, type: String.self)
        case .int:
            homogeneous(values: values, type: Int64.self)
        case .double:
            homogeneous(values: values, type: Double.self)
        case .date:
            homogeneous(values: values, type: Date.self)
        default:
            nil
        }
    }

    private static func homogeneous<T: RecordListElement>(values: [RecordValue], type: T.Type) -> RecordValue? {
        let members = values.compactMap(T.init(recordValue:))
        return members.count == values.count ? T.list(members) : nil
    }
}
