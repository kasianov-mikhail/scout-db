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

        let heads = HeadPages(database: database, slots: slots)
        let plans = try await heads.plans(entity: entity, aggregates: aggregates)

        let deltas = aggregates.deltas(
            old: old,
            new: new,
            now: Date(),
            spread: plans
        )

        let loader = VectorLoader(database: database, slots: slots)
        let opened = try await loader.open(deltas: deltas)
        let writer = VectorIndexWriter(database: database)

        try await writer.write(wanted: opened.cold.indexPages)

        let saver = VectorSaver(database: database, slots: slots)
        let outcome = try await saver.save(pending: opened.pending)

        try await heads.raise(pages: plans.raised(lost: outcome.lost))

        if let stranded = outcome.stranded {
            throw RecordConflictError(serverRecord: stranded)
        }
    }
}
