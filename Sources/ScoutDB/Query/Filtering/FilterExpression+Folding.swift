//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension FilterExpression {
    static func folding(_ left: [[EntityStore.Filter]], _ right: [[EntityStore.Filter]]) -> EntityStore.Filter? {
        guard left.count == 1, right.count == 1 else {
            return nil
        }
        guard let lhs = left[0].only, let rhs = right[0].only, lhs.field == rhs.field else {
            return nil
        }
        guard let values = membership(of: lhs.values + rhs.values) else {
            return nil
        }
        return EntityStore.Filter(field: lhs.field, op: .in, value: values)
    }

    private static func membership(of values: [RecordValue]) -> RecordValue? {
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

    private static func homogeneous<Element: RecordListElement>(
        _ values: [RecordValue], of _: Element.Type
    ) -> RecordValue? {
        let members = values.compactMap(Element.init(recordValue:))
        return members.count == values.count ? Element.list(members) : nil
    }
}

extension EntityStore.Filter {
    fileprivate var values: [RecordValue] {
        switch op {
        case .equals:
            return [value]
        case .in:
            return value.members ?? []
        default:
            return []
        }
    }
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
