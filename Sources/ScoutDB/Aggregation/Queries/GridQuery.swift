//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct GridQuery {
    let store: EntityStore
    let entity: String
    let view: String
    var group: String?
    var from: Date?
    var to: Date?

    init(_ store: EntityStore, entity: String, view: String, group: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.store = store
        self.entity = entity
        self.view = view
        self.group = group
        self.from = from
        self.to = to
    }

    static func merging<Row>(_ rows: [Row], sharding key: (Row) -> String, _ combine: (Row, Row) -> Row) -> [Row] {
        Dictionary(grouping: rows, by: key).values.map { shards in
            shards.dropFirst().reduce(shards[0], combine)
        }
    }

    static func combined(_ lhs: Double?, _ rhs: Double?, _ kind: Metric?) -> Double? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return kind?.combine(lhs, rhs) ?? lhs + rhs
    }
}
