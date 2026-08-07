//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension [AggregateDefinition] {
    func deltas(removing old: [EntityRecord], adding new: [EntityRecord], at now: Date, spread: ShardPlans) -> Deltas {
        var merged: Deltas = [:]

        for (batch, adding) in [(old, false), (new, true)] {
            for entityRecord in batch {
                for aggregate in self {
                    let stamp = aggregate.stamp(of: entityRecord, at: now)
                    let week = stamp.weekStart

                    let slot = VectorSlot(
                        for: entityRecord,
                        aggregate: aggregate,
                        week: week,
                        shards: spread[aggregate.name]?.count(for: week) ?? aggregate.shards
                    )

                    guard let slot else {
                        continue
                    }
                    guard let one = aggregate.delta(for: entityRecord, at: stamp.hourOfWeek) else {
                        continue
                    }

                    let folded = adding ? one : one.reversed()
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
    fileprivate func stamp(of entityRecord: EntityRecord, at now: Date) -> Date {
        guard let date, case .date(let value)? = entityRecord.values[date] else {
            return now
        }
        return value
    }

    fileprivate func delta(for entityRecord: EntityRecord, at hour: Int) -> VectorDelta? {
        guard let field = measure?.field else {
            return VectorDelta(kind: fold, cells: [hour: 1])
        }
        guard let value = entityRecord.values[field]?.scalar else {
            return nil
        }
        return VectorDelta(kind: fold, cells: [hour: value])
    }
}
