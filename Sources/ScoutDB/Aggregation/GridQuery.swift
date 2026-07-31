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

    init(_ store: EntityStore, entity: String, view: String, group: String? = nil) {
        self.store = store
        self.entity = entity
        self.view = view
        self.group = group
    }
}

func combined(_ lhs: Double?, _ rhs: Double?, _ kind: Metric?) -> Double? {
    guard let lhs else {
        return rhs
    }
    guard let rhs else {
        return lhs
    }
    return kind?.combine(lhs, rhs) ?? lhs + rhs
}
