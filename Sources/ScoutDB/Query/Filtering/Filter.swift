//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct Filter: Equatable, Sendable {
    let field: String
    let op: Operator
    let value: RecordValue
}

extension Filter {
    init?(folding left: [[Self]], _ right: [[Self]]) {
        guard left.count == 1, right.count == 1 else {
            return nil
        }
        guard let lhs = left[0].only, let rhs = right[0].only, lhs.field == rhs.field else {
            return nil
        }
        guard let values = RecordValue.membership(of: lhs.values + rhs.values) else {
            return nil
        }
        self.init(field: lhs.field, op: .in, value: values)
    }

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
