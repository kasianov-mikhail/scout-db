//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct FieldOrder: SortComparator, Hashable, Sendable {
    enum Key: Hashable, Sendable {
        case field(name: String)
        case uuid
    }

    let key: Key
    var order: SortOrder = .forward

    func compare(_ lhs: EntityRecord, _ rhs: EntityRecord) -> ComparisonResult {
        switch order {
        case .forward:
            rank(lhs: lhs, rhs: rhs)
        case .reverse:
            rank(lhs: rhs, rhs: lhs)
        }
    }

    private func rank(lhs: EntityRecord, rhs: EntityRecord) -> ComparisonResult {
        switch key {
        case .field(name: let name):
            RecordValue.rank(lhs: lhs.values[name], rhs: rhs.values[name])
        case .uuid:
            RecordValue.rank(lhs: .string(lhs.uuid), rhs: .string(rhs.uuid))
        }
    }
}
