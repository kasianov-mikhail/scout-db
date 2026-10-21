//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorAggregator {
    let database: any CloudDatabase
    let aggregates: [AggregateDefinition]
    let slots: VectorCache

    func rebalance(old: [EntityRecord], new: [EntityRecord]) async throws {
        guard !aggregates.isEmpty, let entity = (new.first ?? old.first)?.entity else {
            return
        }

        let ids = aggregates.map { VectorIndex(entity: entity, aggregate: $0.name).recordID }
        let heads = try await slots.records(ids: ids, database: database)
        await slots.keep(records: heads.fetched)

        let layout = ShardLayout(
            zip(aggregates, ids).map { aggregate, id in
                ShardPlan(aggregate: aggregate, head: heads.records[id]?.indexPage)
            }
        )

        let deltas = layout.deltas(old: old, new: new, now: Date())
        let opened = try await open(deltas: deltas)

        try await database.write(wanted: opened.cold.indexPages)

        let outcome = try await save(pending: opened.pending)
        let raised = layout.raised(lost: outcome.lost)

        try await database.write(wanted: raised)

        for index in raised.keys {
            await slots.forget(id: index.recordID)
        }

        if let stranded = outcome.stranded {
            throw RecordConflictError(serverRecord: stranded)
        }
    }
}
