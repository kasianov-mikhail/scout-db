//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

// Which declared aggregate answers a read, and which of its groups the query
// narrows to. Shared by the reads that fold a vector whole and the ones that
// unfold it hour by hour, so both refuse the same queries for the same reasons.
struct AggregateMatch {
    let definition: EntityDefinition
    let branches: [[ClientFilter]]

    func aggregate(field: String?, metric: Metric, groups: [String]) throws -> AggregateDefinition {
        let grouping = definition.aggregates.filter { $0.groups == groups }

        guard let aggregate = grouping.covering(field, folding: metric) else {
            throw SchemaError.unsupportedQuery(
                .noAggregate(
                    entity: definition.entity,
                    grouping: groups.isEmpty ? nil : groups.joined(separator: "+"),
                    folding: field
                )
            )
        }
        return aggregate
    }

    func groups(narrowedTo groups: [String]) throws -> [String]? {
        guard branches.count == 1 else {
            throw SchemaError.unsupportedQuery(.disjunctionUnsupported)
        }

        var narrowed: [String]?
        for filter in branches[0] {
            guard groups.count == 1, filter.field == groups[0], filter.op == .equals else {
                throw SchemaError.unsupportedQuery(
                    .equalityOnly(group: groups.isEmpty ? nil : groups.joined(separator: "+"))
                )
            }
            let key = filter.value.canonical
            narrowed = narrowed.map { $0.contains(key) ? [key] : [] } ?? [key]
        }
        return narrowed
    }
}
