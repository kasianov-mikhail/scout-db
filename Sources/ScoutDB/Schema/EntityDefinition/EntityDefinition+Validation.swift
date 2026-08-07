//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    func validate() throws {
        guard !entity.hasPrefix("__") else {
            throw SchemaError.invalidDefinition(.reservedEntity(entity))
        }

        let names = Set(fields.map(\.name))
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                guard field.type == pool else {
                    throw SchemaError.invalidDefinition(
                        .slotTypeMismatch(field: field.name, type: field.type, pool: pool)
                    )
                }
                guard let index = pool.slotIndex(slot) else {
                    throw SchemaError.invalidDefinition(.slotOutsidePool(slot, pool: pool))
                }
                guard index >= pool.reserved else {
                    throw SchemaError.invalidDefinition(.reservedSlot(slot, pool: pool))
                }
                guard index < pool.capacity else {
                    throw SchemaError.invalidDefinition(.slotBeyondCapacity(slot, pool: pool))
                }
            }
            if case .payload(let slot) = field.storage {
                guard let index = PayloadPool.slotIndex(slot) else {
                    throw SchemaError.invalidDefinition(.slotOutsidePayload(slot))
                }
                guard index < PayloadPool.capacity else {
                    throw SchemaError.invalidDefinition(.slotBeyondPayload(slot))
                }
            }
            if let pattern = field.pattern {
                guard [.string, .text, .stringList].contains(field.type) else {
                    throw SchemaError.invalidDefinition(
                        .unsupportedPattern(field: field.name, type: field.type)
                    )
                }
                guard (try? Regex(pattern)) != nil else {
                    throw SchemaError.invalidDefinition(.malformedPattern(field: field.name))
                }
            }
            if field.allowed != nil, ![.string, .text, .stringList].contains(field.type) {
                throw SchemaError.invalidDefinition(
                    .unsupportedAllowed(field: field.name, type: field.type)
                )
            }
            if field.min != nil || field.max != nil, ![.int, .double, .intList, .doubleList].contains(field.type) {
                throw SchemaError.invalidDefinition(
                    .unsupportedBounds(field: field.name, type: field.type)
                )
            }
        }
        for lhs in fields {
            for rhs in fields where lhs.name != rhs.name || lhs.since != rhs.since {
                let slot = lhs.storage.slot
                guard slot == rhs.storage.slot else {
                    continue
                }
                if (lhs.since ?? 1) < (rhs.until ?? .max), (rhs.since ?? 1) < (lhs.until ?? .max) {
                    throw SchemaError.invalidDefinition(.sharedSlot(lhs.name, rhs.name, slot: slot))
                }
            }
        }
        for aggregate in aggregates {
            if let groupBy = aggregate.groupBy, !names.contains(groupBy) {
                throw SchemaError.invalidDefinition(
                    .unknownGrouping(aggregate: aggregate.name, field: groupBy)
                )
            }

            if let date = aggregate.date {
                guard let field = fields.first(where: { $0.name == date }) else {
                    throw SchemaError.invalidDefinition(
                        .unknownDate(aggregate: aggregate.name, field: date)
                    )
                }
                guard field.type == .timestamp else {
                    throw SchemaError.invalidDefinition(
                        .nonTemporalDate(aggregate: aggregate.name, field: date)
                    )
                }
            }

            if let histogram = aggregate.measure?.histogram {
                guard aggregate.groupBy == nil else {
                    throw SchemaError.invalidDefinition(.groupedHistogram(aggregate: aggregate.name))
                }
                guard (1...63).contains(histogram.bounds.count) else {
                    throw SchemaError.invalidDefinition(.invalidBounds(aggregate: aggregate.name))
                }
                guard histogram.bounds == histogram.bounds.sorted(),
                    Set(histogram.bounds).count == histogram.bounds.count
                else {
                    throw SchemaError.invalidDefinition(.invalidBounds(aggregate: aggregate.name))
                }
            }

            if let field = aggregate.measure?.field ?? aggregate.measure?.histogram?.field {
                guard let type = fields.first(where: { $0.name == field })?.type, type == .int || type == .double else {
                    throw SchemaError.invalidDefinition(
                        .nonNumericMetric(aggregate: aggregate.name, field: field)
                    )
                }
            }

            if let shards = aggregate.shards, !(2...64).contains(shards) {
                throw SchemaError.invalidDefinition(.invalidShards(aggregate: aggregate.name))
            }
        }
    }
}
