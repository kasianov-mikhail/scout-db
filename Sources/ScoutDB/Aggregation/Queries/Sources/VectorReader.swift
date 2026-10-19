//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorReader {
    let database: any CloudDatabase
    let definition: EntityDefinition
    let aggregate: AggregateDefinition

    func rows(groups: [String]?, in range: Range<Date>? = nil) async throws -> [VectorRow] {
        let fetch = VectorFetch(
            database: database,
            entity: definition.entity,
            aggregate: aggregate
        )

        guard let since = aggregate.since, let date = aggregate.date else {
            return try await fetch.rows(groups: groups, range: range)
        }

        if let bound = range?.lowerBound, bound >= since {
            return try await fetch.rows(groups: groups, range: range)
        }

        let fold = RecordFold(
            database: database,
            definition: definition,
            aggregate: aggregate,
            date: date,
            since: since
        )

        async let counted = fetch.rows(groups: groups, range: range)
        async let missing = fold.rows(groups: groups, range: range)

        return try await counted.compactMap { $0.trimmed(since: since) } + missing
    }

    func cells(groups: [String]?, range: Range<Date>) async throws -> [SeriesPoint.Key: Double] {
        let cells = try await rows(groups: groups, in: range).vectorCells(folding: aggregate.fold, in: range)
        return aggregate.measure?.metric == nil ? cells.filter { $0.value != 0 } : cells
    }
}
