//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct FieldOrder: SortComparator, Hashable, Sendable {
    enum Key: Hashable, Sendable {
        case field(String)
        case uuid
    }

    let key: Key
    var order: SortOrder = .forward

    func compare(_ lhs: EntityRecord, _ rhs: EntityRecord) -> ComparisonResult {
        switch order {
        case .forward:
            rank(lhs, rhs)
        case .reverse:
            rank(rhs, lhs)
        }
    }

    private func rank(_ lhs: EntityRecord, _ rhs: EntityRecord) -> ComparisonResult {
        switch key {
        case .field(let name):
            RecordValue.rank(lhs.values[name], rhs.values[name])
        case .uuid:
            RecordValue.rank(.string(lhs.uuid), .string(rhs.uuid))
        }
    }
}
