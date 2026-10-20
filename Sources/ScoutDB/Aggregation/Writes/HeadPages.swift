//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct HeadPages {
    let database: any CloudDatabase
    let slots: VectorCache

    func plans(entity: String, aggregates: [AggregateDefinition]) async throws -> ShardPlans {
        let ids = aggregates.map { VectorIndex(entity: entity, aggregate: $0.name).recordID }
        let served = try await slots.records(ids: ids, database: database)
        await slots.keep(records: served.fetched)

        return ShardPlans(
            uniqueKeysWithValues: zip(aggregates, ids).map { aggregate, id in
                (aggregate.name, ShardPlan(aggregate: aggregate, head: served.records[id]?.indexPage))
            }
        )
    }

    func raise(pages: [VectorIndex: IndexPage]) async throws {
        try await VectorIndexWriter(database: database).write(wanted: pages)

        for index in pages.keys {
            await slots.forget(id: index.recordID)
        }
    }
}
