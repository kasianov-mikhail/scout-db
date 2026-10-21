//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension ShardLayout {
    func deltas(old: [EntityRecord], new: [EntityRecord], now: Date) -> Deltas {
        var merged: Deltas = [:]

        for (batch, adding) in [(old, false), (new, true)] {
            for entityRecord in batch {
                for plan in plans.values {
                    let aggregate = plan.aggregate
                    let stamp = aggregate.stamp(entityRecord: entityRecord, now: now)
                    let week = stamp.weekStart

                    let slot = VectorSlot(
                        entityRecord: entityRecord,
                        aggregate: aggregate,
                        week: week,
                        shards: plan.count(week: week)
                    )

                    guard let slot else {
                        continue
                    }
                    guard let one = aggregate.delta(entityRecord: entityRecord, hour: stamp.hourOfWeek) else {
                        continue
                    }

                    let folded = adding ? one : one.inverse
                    merged[slot, default: VectorDelta(kind: folded.kind)]
                        .cells
                        .merge(folded.cells, uniquingKeysWith: folded.kind.combine)
                }
            }
        }

        return merged.filter { !$0.value.isNoop }
    }
}

extension AggregateDefinition {
    fileprivate func stamp(entityRecord: EntityRecord, now: Date) -> Date {
        guard let date, case .date(let value)? = entityRecord.values[date] else {
            return now
        }
        return value
    }

    fileprivate func delta(entityRecord: EntityRecord, hour: Int) -> VectorDelta? {
        guard let field = measure?.field else {
            return VectorDelta(kind: fold, cells: [hour: 1])
        }
        guard let value = entityRecord.values[field]?.scalar else {
            return nil
        }
        return VectorDelta(kind: fold, cells: [hour: value])
    }
}
