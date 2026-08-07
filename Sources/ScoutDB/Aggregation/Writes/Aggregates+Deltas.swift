//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateDeltas {
    var integers: [VectorSlot<IntVector>: VectorDelta<IntVector>] = [:]
    var doubles: [VectorSlot<DoubleVector>: VectorDelta<DoubleVector>] = [:]

    var isEmpty: Bool {
        integers.isEmpty && doubles.isEmpty
    }
}

extension EntityDefinition {
    func deltas(
        _ aggregates: [AggregateDefinition], removing old: [EntityRecord], adding new: [EntityRecord], at now: Date
    ) -> AggregateDeltas {
        var deltas = AggregateDeltas()

        for (batch, adding) in [(old, false), (new, true)] {
            for entityRecord in batch {
                for aggregate in aggregates {
                    let stamp = aggregate.stamp(of: entityRecord, at: now)
                    let week = stamp.weekStart
                    let hour = stamp.hourOfWeek

                    if isInteger(aggregate) {
                        guard
                            let slot = VectorSlot<IntVector>(for: entityRecord, aggregate: aggregate, week: week),
                            let value = aggregate.integer(of: entityRecord)
                        else {
                            continue
                        }
                        deltas.integers.fold(
                            VectorDelta(kind: aggregate.fold, cells: [hour: value]), into: slot, adding: adding)
                    } else {
                        guard
                            let slot = VectorSlot<DoubleVector>(for: entityRecord, aggregate: aggregate, week: week),
                            let value = aggregate.scalar(of: entityRecord)
                        else {
                            continue
                        }
                        deltas.doubles.fold(
                            VectorDelta(kind: aggregate.fold, cells: [hour: value]), into: slot, adding: adding)
                    }
                }
            }
        }

        deltas.integers = deltas.integers.filter { !$0.value.isNoop }
        deltas.doubles = deltas.doubles.filter { !$0.value.isNoop }

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
    fileprivate func stamp(of entityRecord: EntityRecord, at now: Date) -> Date {
        guard let date, case .date(let value)? = entityRecord.values[date] else {
            return now
        }
        return value
    }

    fileprivate func integer(of entityRecord: EntityRecord) -> Int64? {
        guard let field = measure?.field else {
            return 1
        }
        return entityRecord.values[field]?.integer
    }

    fileprivate func scalar(of entityRecord: EntityRecord) -> Double? {
        measure?.field.flatMap { entityRecord.values[$0]?.scalar }
    }
}
