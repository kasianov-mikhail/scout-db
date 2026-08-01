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
    var order: SortOrder

    static let uuid = FieldOrder(key: .uuid, order: .forward)

    static func field(_ name: String, _ order: SortOrder = .forward) -> FieldOrder {
        FieldOrder(key: .field(name), order: order)
    }

    init(key: Key, order: SortOrder) {
        self.key = key
        self.order = order
    }

    init(_ sort: EntityStore.Sort) {
        self.init(key: .field(sort.field), order: sort.ascending ? .forward : .reverse)
    }

    func compare(_ lhs: EntityRecord, _ rhs: EntityRecord) -> ComparisonResult {
        let result = RecordValue.rank(value(of: lhs), value(of: rhs))
        guard order == .reverse else {
            return result
        }
        return switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }

    private func value(of record: EntityRecord) -> RecordValue? {
        switch key {
        case .field(let name):
            record.values[name]
        case .uuid:
            .string(record.uuid)
        }
    }
}
