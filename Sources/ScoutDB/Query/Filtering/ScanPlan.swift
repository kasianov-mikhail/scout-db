//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct ScanPlan {
    let query: CKQuery
    let remaining: [ClientFilter]
    var included: (EntityRecord) -> Bool = { _ in true }

    func includes(_ record: EntityRecord) -> Bool {
        remaining.allSatisfy { $0.matches(record) ?? false } && included(record)
    }
}

extension EntityDefinition {
    func plan(matching filters: [ClientFilter], sort: [CKQuery.Sort]) throws -> ScanPlan {
        ScanPlan(
            query: CKQuery(
                recordType: "Entity",
                filters: try serverFilters(filters),
                sort: sort
            ),
            remaining: try clientFilters(filters)
        )
    }
}
