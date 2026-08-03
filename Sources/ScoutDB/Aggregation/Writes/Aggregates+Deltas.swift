//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension [AggregateDefinition] {
    func deltas(removing old: [EntityRecord], adding new: [EntityRecord]) -> [GridSlot: GridDelta] {
        var merged: [GridSlot: GridDelta] = [:]

        for (batch, adding) in [(old, false), (new, true)] {
            for entityRecord in batch {
                for aggregate in self {
                    let slot = GridSlot(for: entityRecord, aggregate: aggregate)
                    let one = delta(for: entityRecord, in: aggregate)

                    merged[slot] = merged[slot, default: GridDelta()] + (adding ? one : one.reversed())
                }
            }
        }

        return merged.filter { !$0.value.isNoop }
    }

    private func delta(for entityRecord: EntityRecord, in aggregate: AggregateDefinition) -> GridDelta {
        guard let kind = aggregate.metricKind, let field = aggregate.metricField,
            let value = entityRecord.values[field]?.scalar
        else {
            return GridDelta(count: 1)
        }
        return GridDelta(count: 1, total: GridTotal(kind: kind, value: value))
    }
}

extension GridDelta {
    var isNoop: Bool {
        guard count == 0 else {
            return false
        }
        guard let total else {
            return true
        }
        return total.isNoop
    }
}
