//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateDeltas {
    var counts: [VectorSlot<IntVector>: VectorDelta<IntVector>] = [:]
    var measures: [VectorSlot<DoubleVector>: VectorDelta<DoubleVector>] = [:]

    var isEmpty: Bool {
        counts.isEmpty && measures.isEmpty
    }
}

extension [AggregateDefinition] {
    func deltas(removing old: [EntityRecord], adding new: [EntityRecord], at now: Date) -> AggregateDeltas {
        var deltas = AggregateDeltas()

        for (batch, adding) in [(old, false), (new, true)] {
            for entityRecord in batch {
                for aggregate in self {
                    let stamp = aggregate.stamp(of: entityRecord, at: now)
                    let week = stamp.weekStart
                    let hour = stamp.hourOfWeek

                    if aggregate.counts {
                        guard let slot = VectorSlot<IntVector>(for: entityRecord, aggregate: aggregate, week: week)
                        else {
                            continue
                        }
                        deltas.counts.fold(
                            VectorDelta(kind: aggregate.fold, cells: [hour: 1]), into: slot, adding: adding)
                    } else {
                        guard
                            let slot = VectorSlot<DoubleVector>(for: entityRecord, aggregate: aggregate, week: week),
                            let value = aggregate.value(of: entityRecord)
                        else {
                            continue
                        }
                        deltas.measures.fold(
                            VectorDelta(kind: aggregate.fold, cells: [hour: value]), into: slot, adding: adding)
                    }
                }
            }
        }

        deltas.counts = deltas.counts.filter { !$0.value.isNoop }
        deltas.measures = deltas.measures.filter { !$0.value.isNoop }

        return deltas
    }
}

extension Dictionary {
    fileprivate mutating func fold<Holder: Vector>(
        _ delta: VectorDelta<Holder>, into slot: VectorSlot<Holder>, adding: Bool
    ) where Key == VectorSlot<Holder>, Value == VectorDelta<Holder> {
        let folded = adding ? delta : delta.reversed()

        self[slot, default: VectorDelta(kind: folded.kind)]
            .cells
            .merge(folded.cells, uniquingKeysWith: folded.kind.combine)
    }
}

extension AggregateDefinition {
    var counts: Bool {
        measure?.field == nil
    }

    fileprivate func stamp(of entityRecord: EntityRecord, at now: Date) -> Date {
        guard let date, case .date(let value)? = entityRecord.values[date] else {
            return now
        }
        return value
    }

    fileprivate func value(of entityRecord: EntityRecord) -> Double? {
        measure?.field.flatMap { entityRecord.values[$0]?.scalar }
    }
}
