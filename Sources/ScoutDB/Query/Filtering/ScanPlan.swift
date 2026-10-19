//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct ScanPlan {
    let query: CKQuery
    let desiredKeys: [String]?
    let remaining: [ClientFilter]
    var included: (EntityRecord) -> Bool = { _ in true }

    func includes(record: EntityRecord) -> Bool {
        remaining.allSatisfy { $0.matches(record: record) ?? false } && included(record)
    }
}

extension EntityDefinition {
    func plan(filters: [ClientFilter], sort: [CKQuery.Sort], fields: [String]?) throws -> ScanPlan {
        let remaining = try clientFilters(filters: filters)

        return ScanPlan(
            query: CKQuery(
                recordType: "Entity",
                filters: try serverFilters(filters: filters),
                sort: sort
            ),
            desiredKeys: try fields.map { try keys(names: $0 + remaining.map(\.field)) },
            remaining: remaining
        )
    }

    func keys(names: [String]) throws -> [String] {
        var keys: Set = [Envelope.entity, Envelope.version, Envelope.uuid]

        for name in names {
            let slots = fields.filter { $0.name == name }.map(\.storage.slot)
            guard !slots.isEmpty else {
                throw SchemaError.unknownField(name)
            }
            keys.formUnion(slots)
        }

        return keys.sorted()
    }
}
